local spec = dofile('tests/lua/spec_helper.lua')
local rpc = dofile('scripts/core/share/xudp_rpc.lua')
local motion = dofile('scripts/core/share/xudp_move.lua')
local sessions = dofile('scripts/core/share/xudp_session.lua')
local notify = dofile('scripts/core/share/xudp_notify.lua')
local json = require('xutils')

local function sender(overrides)
    local seq, packets = 0, {}
    local o = {now=0,max_messages=8,max_bytes=4096,max_message_bytes=512,max_batch_bytes=1024,
        heartbeat_ms=1000,retry_ms=10,retry_max_ms=40,send_retry_ms=5,round_timeout_ms=500,
        session_timeout_ms=1000,max_attempts=8,compare_ids=function(a,b) return tonumber(a)>tonumber(b) and 1 or -1 end,
        next_id=function() seq=seq+1; return tostring(seq) end,
        pack=function(_,messages) return table.concat(messages,'|'),#messages end,
        send_ping=function(id,body) packets[#packets+1]={id,body}; return true end}
    for k,v in pairs(overrides or {}) do o[k]=v end
    return notify.new_sender(o),packets
end
local function record_queue(q)
    return function(kind,id,success,payload,key)
        return q:enqueue(kind..':'..id..':'..tostring(success)..':'..tostring(payload),key)
    end
end

spec.describe('RPC admission and shared notification queue',function()
    spec.it('registers before dispatch and suppresses a delayed acceptance on fast completion',function()
        local q,packets=sender()
        local executions,s=0,nil
        s=rpc.new_server({publish=record_queue(q),dispatch=function(id,request)
            executions=executions+1
            assert(s:request(id,request,0))
            assert(s:complete(id,true,'done',0))
            return true
        end})
        assert(s:request('1','cast',0)); assert(q:step(0))
        spec.equal(executions,1)
        spec.equal(packets[1][2],'RPC_RESULT:1:true:done')
        local ok,why=s:request('1','other',1)
        spec.equal(ok,false);spec.equal(why,'conflicting_request')
        spec.equal(s:complete('1',false,'late',1),false)
    end)

    spec.it('replaces a pending ACCEPTED but keeps an in-flight ACCEPTED immutable',function()
        local q,packets=sender()
        local s=rpc.new_server({publish=record_queue(q),dispatch=function() return true end})
        assert(s:request('1','slow',0));s:step(10)
        assert(s:complete('1',true,'fast-enough',11));assert(q:step(11))
        spec.equal(packets[1][2],'RPC_RESULT:1:true:fast-enough')
        assert(q:ack('1',12))
        assert(s:request('2','slow',13));s:step(23);assert(q:step(23))
        spec.equal(packets[2][2],'RPC_ACCEPTED:2:nil:nil')
        assert(s:complete('2',true,'later',24))
        assert(q:step(33))
        spec.equal(packets[3][2],packets[2][2])
        assert(q:ack('2',34))
        spec.equal(packets[4][2],'RPC_RESULT:2:true:later')
    end)

    spec.it('bounds cached results and rejects retired IDs without reexecution',function()
        local q=sender()
        local count=0
        local s=rpc.new_server({max_records=1,result_ttl_ms=20,publish=record_queue(q),
            dispatch=function() count=count+1;return true end})
        assert(s:request('1','cast',0))
        spec.equal(s:request('2','next',1),false)
        assert(s:complete('1',true,'result',2))
        assert(s:query('1',3))
        spec.equal(count,1)
        s:step(22);spec.equal(s.count,0);spec.equal(s.bytes,0)
        local ok,why=s:request('1','cast',23)
        spec.equal(ok,false);spec.equal(why,'expired');spec.equal(count,1)
        assert(s:query('1',23))
        spec.equal(s:request('2','next',24),false)
        assert(s:request('3','next',24));spec.equal(count,2)
    end)

    spec.it('reserves result capacity, retries publication, and reports dispatch rejection',function()
        local published,allow={},false
        local s=rpc.new_server({max_bytes=40,max_result_bytes=32,max_request_bytes=8,
            publish=function(kind,_,_,payload)
                if not allow then return false end
                published[#published+1]={kind,payload};return true
            end,dispatch=function() return false end})
        assert(s:request('1','cast',0))
        spec.equal(#published,0)
        spec.equal(s.records['1'].payload,'dispatch_rejected')
        allow=true;s:step(9);spec.equal(#published,0)
        s:step(10);spec.equal(#published,1);spec.equal(published[1][1],'RPC_RESULT')
        spec.equal(s:request('2','12345678',11),false)
    end)

    spec.it('coalesces repeated queries and never frees the result cache on Pong',function()
        local q,packets=sender()
        local s=rpc.new_server({publish=record_queue(q),dispatch=function() return true end})
        assert(s:request('1','slow',0));s:step(10)
        for t=11,30 do assert(s:query('1',t)) end
        spec.equal(q:status().held_messages,1)
        assert(s:complete('1',true,'done',31));assert(q:step(31));assert(q:ack('1',32))
        spec.equal(s.records['1'].payload,'done')
        assert(s:query('1',33));assert(q:step(33))
        spec.equal(packets[2][2],packets[1][2])
    end)
end)

spec.describe('serialized client RPC',function()
    spec.it('buffers the next call until a terminal result and completes each once',function()
        local sent={}
        local c=rpc.new_client({send=function(kind,id,request) sent[#sent+1]={kind,id,request};return true end,
            request_retry_ms=10,query_retry_ms=20,retry_max_ms=40})
        spec.equal(c:request('first',0),'1');spec.equal(c:request('second',0),'2')
        spec.equal(#sent,1)
        assert(c:step(10));spec.equal(sent[2][2],'1')
        assert(c:receive('RPC_ACCEPTED','1',nil,nil,11))
        assert(c:step(30));spec.equal(#sent,2)
        assert(c:step(31));spec.equal(sent[3][1],'RPC_QUERY')
        assert(c:receive('RPC_RESULT','1',true,'first-done',32))
        spec.equal(sent[4][2],'2')
        spec.equal(c:receive('RPC_RESULT','1',true,'duplicate',33),false)
        assert(c:receive('RPC_RESULT','2',true,'second-done',34)) -- result before ACCEPTED
        local id,ok,result=c:take_result()
        spec.equal(id,'1');spec.equal(ok,true);spec.equal(result,'first-done')
        spec.equal(c:take_result(),'2');spec.equal(c:take_result(),nil)
    end)

    spec.it('does not release buffered calls on unknown outcome, timeout or local failure',function()
        local sent={}
        local c=rpc.new_client({max_calls=2,timeout_ms=25,request_retry_ms=10,
            send=function(kind,id) sent[#sent+1]={kind,id};return false end})
        assert(c:request('first',0));assert(c:request('second',0))
        spec.equal(c:request('full',0),nil)
        assert(c:receive('RPC_STATUS','1',false,'unknown',20))
        local ok,why=c:step(25)
        spec.equal(ok,false);spec.equal(why,'timeout');spec.equal(c.active.id,'1')
        for _,p in ipairs(sent) do spec.equal(p[2],'1') end
        assert(c:receive('RPC_RESULT','1',false,'late-final',26))
        spec.equal(c.active.id,'2')
        c:close();spec.equal(c:request('closed',27),nil)
    end)
end)

spec.describe('MOVE coalescing and reliable pause versions',function()
    local function state(motion,seq,payload,gen)
        return {entity='player',generation=gen or 1,motion=motion,sequence=seq,payload=payload or 'position'}
    end
    spec.it('keeps only the latest state while blocked and enforces budgets',function()
        local sent,allowed={},false
        local s=motion.new_sender({max_entities=1,max_bytes=32,send_budget=1,send=function(v)
            if not allowed then return false end
            sent[#sent+1]=v;return true
        end})
        assert(s:put(state(1,1)));assert(s:put(state(1,2,'latest')))
        spec.equal(#s.order,1);spec.equal(s:flush(),0)
        allowed=true;spec.equal(s:flush(),1);spec.equal(sent[1].payload,'latest')
        spec.equal(s:put(state(1,1)),false)
        local other=state(1,1);other.entity='other';spec.equal(s:put(other),false)
        s:forget('player');assert(s:put(other))
    end)
    spec.it('requires a baseline and skips old pause only after a newer MOVE was accepted',function()
        local c=motion.new_receiver()
        spec.equal(c:accept(state(10,1)),false)
        assert(c:baseline('player',1));assert(c:accept(state(10,1)))
        assert(c:accept(state(11,1,'pause'))) -- newer MOVE may never arrive
        spec.equal(c:accept(state(10,2)),false)
        assert(c:accept(state(12,1)))
        spec.equal(c:accept(state(11,1,'late-pause')),false)
        assert(c:baseline('player',2))
        spec.equal(c:accept(state(99,99,'old-generation',1)),false)
        assert(c:accept(state(1,1,'new-generation',2)))
    end)
end)

spec.describe('cross-thread send receipts',function()
    spec.it('advances heartbeat only on actual acceptance and ignores stale receipts',function()
        local q=sender({send_ping=function() return nil,'pending' end})
        assert(q:enqueue('A'));assert(q:step(10))
        spec.equal(q:status().next_heartbeat,1000)
        assert(q:step(20));spec.equal(q:status().sent,0)
        spec.equal(q:ack('1',20),false)
        spec.equal(q:send_result('old',1,true,20),false)
        spec.equal(q:send_result('1',1,false,21),false)
        assert(q:step(26));assert(q:send_result('1',2,true,27))
        spec.equal(q:status().next_heartbeat,1027)
        spec.equal(q:send_result('1',1,true,28),false)
        spec.equal(q:status().next_heartbeat,1027)
        assert(q:ack('1',29))
    end)
end)

-- Default JSON wire exercised over deterministic datagram queues. This is a
-- simulation transport, with the same API as real sendto / main-thread routing.
local function pair(server_options,client_options)
    local to_server,to_client={},{}
    local so={now=0,session_id='test-session',allow_insecure=true,
        send=function(data,_,_,kind) to_client[#to_client+1]={data,kind};return true end,
        dispatch=function() return true end}
    local co={now=0,session_id='test-session',allow_insecure=true,peer_ip='127.0.0.1',peer_port=2000,
        send=function(data,_,_,kind) to_server[#to_server+1]={data,kind};return true end}
    for k,v in pairs(server_options or {}) do so[k]=v end
    for k,v in pairs(client_options or {}) do co[k]=v end
    local s,c=sessions.new_server(so),sessions.new_client(co)
    local function pump(now)
        for _=1,100 do
            local a,b=table.remove(to_server,1),table.remove(to_client,1)
            if not a and not b then return end
            if a then s:receive(a[1],'127.0.0.1',3000,now) end
            if b then c:receive(b[1],'127.0.0.1',2000,now) end
        end
        error('datagram queue did not drain')
    end
    return s,c,to_server,to_client,pump
end

spec.describe('session wire and common protocol path',function()
    spec.it('recovers lost Ping/Pong, serializes RPC, and does not block MOVE',function()
        local executions=0
        local s,c,up,down,pump=pair({dispatch=function() executions=executions+1;return true end})
        assert(c:baseline('player',1));assert(c:rpc_call('cast',0));assert(c:rpc_call('next',0))
        c:step(0);pump(0) -- HELLO / HELLO_OK / RPC #1
        spec.equal(executions,1)
        assert(s:notify('welcome','hi'));s:step(10)
        local lost=table.remove(down,1);spec.equal(lost[2],'PING')
        assert(s:pause({entity='player',generation=1,motion=11,sequence=1,payload='stop'}))
        assert(s:move({entity='player',generation=1,motion=12,sequence=1,payload='moving'}))
        s:step(20);pump(20)
        spec.equal(c:take_move('player').motion,12)
        s:step(110)
        local ping=table.remove(down,1);assert(ping)
        assert(c:receive(ping[1],'127.0.0.1',2000,110))
        table.remove(up,1) -- lose Pong
        s:step(310);pump(310) -- same logical round, new transport sequence
        spec.equal(c:take_notification().name,'welcome')
        spec.equal(c:take_notification(),nil)
        assert(s:complete('1',true,'cast-ok',311));s:step(311);pump(311)
        s:step(312);pump(312)
        spec.equal(c:take_result(),'1');spec.equal(executions,2)
        spec.equal(c.skipped_pauses,1)
        assert(s:complete('2',true,'next-ok',313));s:step(313);pump(313)
        spec.equal(c:take_result(),'2')
    end)

    spec.it('rejects oversized/invalid packets, replay and address changes without mutation',function()
        local s,c,up,down,pump=pair()
        c:step(0);local hello=table.remove(up,1)
        assert(s:receive(hello[1],'127.0.0.1',3000,0))
        spec.equal(s:receive(hello[1],'127.0.0.1',3000,1),false)
        spec.equal(s:receive('R{}','127.0.0.1',3001,2),false)
        spec.equal(s:receive(string.rep('x',1201),'127.0.0.1',3000,3),false)
        local packet='R'..json.json_pack({version=1,session='test-session',sequence=2,kind='HELLO'})
        spec.equal(s:receive(packet,'127.0.0.1',3001,4),false)
        spec.equal(s.peer_port,3000);spec.equal(s.rx_max,1)
        spec.equal(c:rpc_call(string.rep('\0',512),4),nil) -- escaped wire overhead included
        pump(4)
    end)

    spec.it('authenticates before decompression and bounds decompression output',function()
        local calls=0
        local s=sessions.new_server({session_id='secret',send=function() return true end,
            dispatch=function() return true end,seal=function(x) return x end,
            open=function(data) if data=='valid' then return 'Cz' end end,
            compress=function(x) return x end,decompress=function(_,limit)
                calls=calls+1;return string.rep('x',limit+1)
            end})
        local ok,why=s:receive('tampered','127.0.0.1',3000,0)
        spec.equal(ok,false);spec.equal(why,'authentication_failed');spec.equal(calls,0)
        ok,why=s:receive('valid','127.0.0.1',3000,1)
        spec.equal(ok,false);spec.equal(why,'decompress_failed');spec.equal(calls,1)
        spec.equal(s.peer_ip,nil);spec.equal(s.rx_max,0)
    end)

    spec.it('roundtrips optional compression/security hooks with a fresh sequence on logical retries',function()
        -- Test-only reversible maps simulate callback boundaries, not encryption.
        local compressed,sealed,sequence,directions={},{},{},{}
        local serial=0
        local function compress(body)
            serial=serial+1;local key='c'..serial;compressed[key]=body;return key
        end
        local function decompress(body,limit)
            local plain=compressed[body]
            if plain and #plain<=limit then return plain end
        end
        local function seal(body,seq,direction)
            serial=serial+1;local key='s'..serial
            sealed[key]=body;sequence[#sequence+1]=seq;directions[#directions+1]=direction
            return key
        end
        local function open(body) return sealed[body] end
        local hooks={compress=compress,decompress=decompress,seal=seal,open=open,compress_threshold=1}
        local s,c,up,down,pump=pair(hooks,hooks)
        c:step(0);pump(0)
        assert(s:notify('event','payload'));s:step(1)
        local first=table.remove(down,1)
        assert(c:receive(first[1],'127.0.0.1',2000,1))
        table.remove(up,1) -- lose Pong
        s:step(101)
        local second=table.remove(down,1)
        assert(first[1]~=second[1])
        assert(c:receive(second[1],'127.0.0.1',2000,101));pump(101)
        spec.equal(c:take_notification().name,'event');spec.equal(c:take_notification(),nil)
        spec.equal(c:receive(second[1],'127.0.0.1',2000,102),false) -- exact security replay
        spec.equal(directions[1],'c2s');spec.equal(directions[2],'s2c')
        assert(sequence[#sequence]>0)
        s:close();spec.equal(s:notify('closed','data'),false)
    end)

    spec.it('parses the entire batch before Pong/replay admission and backpressures a full application queue',function()
        local s,c,up,down,pump=pair({notify={max_messages=1}},
            {notify={max_messages=1},max_events=1,max_event_bytes=800})
        c:step(0);pump(0)
        local last=c.rx_max
        local bad='R'..json.json_pack({version=1,session='test-session',sequence=10,kind='PING',id='1',
            body=json.json_pack({json.json_pack({kind='NOTIFY',name='valid',payload='value'}),'{}'})})
        spec.equal(c:receive(bad,'127.0.0.1',2000,1),false)
        spec.equal(c.rx_max,last);spec.equal(#up,0);spec.equal(c:take_notification(),nil)
        assert(s:notify('first','1'));s:step(2);pump(2)
        assert(s:notify('second','2'));s:step(3);pump(3)
        spec.equal(s:status().notifications.held_messages,1)
        spec.equal(c:take_notification().name,'first')
        s:step(103);pump(103)
        spec.equal(c:take_notification().name,'second')
        spec.equal(s:status().notifications.held_messages,0)
    end)

    spec.it('rechecks queued pause versions when business drains and forgets departed entities',function()
        local s,c,up,down,pump=pair()
        c:step(0);pump(0);assert(c:baseline('player',1))
        local pause={entity='player',generation=1,motion=1,sequence=1,payload='pause'}
        assert(s:pause(pause));s:step(1);pump(1)
        assert(c:baseline('player',2))
        spec.equal(c:take_notification(),nil) -- old-generation pause was already owned
        pause.generation,pause.motion=2,2
        assert(s:pause(pause));s:step(2);pump(2)
        c:forget_entity('player')
        spec.equal(c:take_notification(),nil)
        spec.equal(c:take_move('player'),nil)
        assert(c:baseline('other',1))
        spec.equal(s:send_result({session='other',id='1',attempt=1},true,3),false)
    end)

    spec.it('rejects raw oversized business data before encoding and encoded MOVE overhead before enqueue',function()
        local packs=0
        local function pack(value) packs=packs+1;return json.json_pack(value) end
        local s,c=pair({pack=pack},{pack=pack})
        local before=packs
        spec.equal(c:rpc_call(string.rep('x',513),0),nil)
        spec.equal(s:complete('1',true,string.rep('x',513),0),false)
        spec.equal(packs,before)
        local state={entity='player',generation=1,motion=1,sequence=1,payload=string.rep('\0',512)}
        local ok,why=s:move(state)
        spec.equal(ok,false);spec.equal(why,'too_large')
        spec.equal(s:status().move_pending,0)
    end)
end)

local failures=spec.finish()
return {__init=function() xthread.stop(failures>0 and 1 or 0) end}
