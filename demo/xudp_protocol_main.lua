-- Run from the root: build.bat udp run-lua demo/xudp_protocol_main.lua
-- Or: make run-lua WITH_UDP=1 SCRIPT=demo/xudp_protocol_main.lua
-- One server UDP socket, multiple workers, multiple logical sessions per worker.
-- Main assigns a worker on the first admitted HELLO and keeps that ownership.
-- xthread.MAIN identifies main; every other thread runs the worker branch.
-- Loopback simulation: fixed demo tokens, explicit plaintext mode, no recovery.
local xnet = require('xnet')
if not xnet.udp_bind then
    return {__init=function()
        print('[UDP-PROTOCOL] SKIP: enable WITH_UDP=1 or build.bat udp')
        xthread.stop(0)
    end}
end
local Session = dofile('scripts/core/share/xudp_session.lua')
local router = dofile('scripts/core/share/xrouter.lua')
local json = require('xutils')
local function now() return xtimer.now_ms() end
local function packet(data)
    if data:sub(1,1)~='R' then return {} end -- this demo explicitly uses plaintext JSON
    local ok,p=pcall(json.json_unpack,data:sub(2))
    return ok and type(p)=='table' and p or {}
end

local current_worker=xthread.current_id()
if current_worker ~= xthread.MAIN then
    local sessions,next_status={},0
    local function state(version,payload)
        return {entity='player',generation=1,motion=version,sequence=1,payload=payload}
    end
    router.register('open_session',function(token)
        assert(not sessions[token],'session was opened twice')
        local record={casts=0,mana=100,empty_pings=0,received=0}
        local function result()
            return json.json_pack({casts=record.casts,mana=record.mana,
                owner=current_worker,session=token})
        end
        record.server=Session.new_server({session_id=token,now=now(),allow_insecure=true,
            notify={heartbeat_ms=100,retry_ms=30,retry_max_ms=120},
            send=function(data,ip,port,kind,context)
                local empty=kind=='PING' and record.server.notifications.current.count==0
                if empty then record.empty_pings=record.empty_pings+1 end
                local ok=xthread.post(xthread.MAIN,'udp_out',current_worker,token,data,ip,port,kind,context)
                if not ok then return false,'route_full' end
                if kind=='PING' then
                    print(string.format('[WORKER %d/%s] PING #%s attempt=%d empty=%s',
                        current_worker,token,context.id,context.attempt,tostring(empty)))
                    return nil,'pending' -- main reports actual sendto acceptance
                end
                return true
            end,
            dispatch=function(id,bytes)
                local request=json.json_unpack(bytes)
                print(string.format('[WORKER %d/%s] RPC_REQUEST #%s %s',current_worker,token,id,request.method))
                if request.method=='cast' then
                    assert(type(request.cost)=='number' and request.cost>=1 and request.cost<=20)
                    record.casts,record.mana=record.casts+1,record.mana-request.cost
                    assert(record.server:notify('skill_started','one skill, one resource deduction'))
                    assert(record.server:move(state(10,'running x=10')))
                    assert(record.server:pause(state(11,'stopped x=11')))
                    assert(record.server:move(state(12,'running x=12')))
                    xtimer.add(180,function()
                        assert(record.server:complete(id,true,result(),now()))
                    end,1)
                elseif request.method=='inspect' then
                    assert(record.server.rpc.records['1'].state=='done','second RPC ran too early')
                    assert(record.server:complete(id,true,result(),now()))
                else return false end
                return true
            end})
        sessions[token]=record
        assert(record.server:notify('welcome','business thread ready'))
        assert(xnet.get_stats().udp_count==0,'worker must not own a UDP socket')
    end)
    router.register('udp_in',function(token,data,ip,port)
        local record=assert(sessions[token],'session routed to the wrong worker')
        assert(packet(data).session==token,'routing token mismatch')
        record.received=record.received+1
        local ok,reason=record.server:receive(data,ip,port,now())
        if not ok then print('[WORKER] rejected datagram: '..tostring(reason)) end
    end)
    router.register('udp_sent',function(token,context,accepted)
        local record=assert(sessions[token],'send receipt routed to wrong worker')
        assert(context.session==token)
        record.server:send_result(context,accepted,now())
    end)
    return {
        __init=function()
            xtimer.init(16)
            assert(xthread.post(xthread.MAIN,'worker_ready',current_worker))
        end,
        __update=function()
            local t=now()
            local report=t>=next_status
            if report then next_status=t+20 end
            local count=0
            for _ in pairs(sessions) do count=count+1 end
            for token,record in pairs(sessions) do
                record.server:step(t)
                if report then
                    local status=record.server:status()
                    assert(xthread.post(xthread.MAIN,'worker_status',current_worker,token,record.casts,
                        record.mana,record.empty_pings,record.received,count,
                        status.notifications.current_id==nil and status.notifications.pending==0))
                end
            end
        end,
        __thread_handle=router.handle,
        __uninit=function() for _,r in pairs(sessions) do r.server:close() end end,
        __tick_ms=1,
    }
end

local WORKERS, CLIENT_COUNT, HOST = {198,199}, 4, '127.0.0.1'
local socket,baseline
local clients,by_session,routes,started,ready,assignment_counts={},{},{},{},{},{}
local done,launched,next_worker=false,false,0
local function finish(ok,message)
    if done then return end
    done=true
    for _,c in ipairs(clients) do
        if c.session then c.session:close() end
        if c.socket then c.socket:close() end
    end
    if socket then socket:close() end
    for _,worker in ipairs(WORKERS) do
        if started[worker] then assert(xthread.shutdown_thread(worker));started[worker]=nil end
    end
    if baseline and xnet.get_stats().fd_count~=baseline then ok,message=false,'fd registrations leaked' end
    print('[UDP-PROTOCOL] '..(ok and 'PASS: ' or 'FAIL: ')..message)
    xthread.stop(ok and 0 or 1)
end

-- This loopback admission table is the simulation's credential check. In a
-- real entry layer, authenticate before admitting/assigning a new session.
local function admit(token,ip,port)
    local c=by_session[token]
    if not c or ip~=HOST or port~=c.port then return nil end
    return c
end
local function route(c)
    local owner=routes[c.token]
    if not owner then
        next_worker=next_worker % #WORKERS+1
        owner=WORKERS[next_worker]
        assert(ready[owner])
        routes[c.token],c.owner=owner,owner
        assignment_counts[owner]=(assignment_counts[owner] or 0)+1
        -- Same-producer FIFO: create the logical session before its first packet.
        assert(xthread.post(owner,'open_session',c.token))
        print(string.format('[MAIN] assign %s to worker %d',c.token,owner))
    end
    assert(owner==c.owner,'session ownership changed')
    return owner
end
router.register('udp_out',function(worker,token,data,ip,port,kind,context)
    if done then return end
    local c=assert(admit(token,ip,port),'reply to an unknown client')
    assert(routes[token]==worker and c.owner==worker,'reply came from the wrong worker')
    local accepted,reason=socket:sendto(data,ip,port)
    if kind=='PING' then
        assert(context.session==token)
        assert(xthread.post(worker,'udp_sent',token,context,accepted))
    end
    if not accepted then finish(false,'server sendto failed: '..tostring(reason)) end
end)
router.register('worker_ready',function(worker)
    assert(started[worker] and not ready[worker])
    ready[worker]=true
    for _,id in ipairs(WORKERS) do if not ready[id] then return end end
    assert(not launched);launched=true
    for _,c in ipairs(clients) do
        assert(c.session:rpc_call(json.json_pack({method='cast',cost=c.cost}),now())=='1')
        assert(c.session:rpc_call(json.json_pack({method='inspect'}),now())=='2')
        assert(c.session:status().rpc_pending==1)
        print('[CLIENT '..c.index..'] RPC #1 active, RPC #2 cached')
    end
end)
router.register('worker_status',function(worker,token,casts,mana,heartbeat,received,count,idle)
    if done then return end
    local c=assert(by_session[token])
    assert(routes[token]==worker and c.owner==worker,'status came from the wrong worker')
    c.status={casts=casts,mana=mana,heartbeat=heartbeat,received=received,count=count,idle=idle}
end)

local function create_client(index,server_ip,server_port)
    local c={index=index,token='loopback-demo-session-'..index,cost=10+index,
        returned=0,business_done=0,busy=false,moved=false,queries=0,reported_skip=0}
    c.socket=assert(xnet.udp_bind(HOST,0,{on_datagram=function(_,data,ip,port)
        if done then return end
        local p=packet(data)
        assert(p.session==c.token,'reply crossed logical sessions')
        if p.kind=='PING' and not c.dropped_ping then
            c.dropped_ping=true;print('[SIM '..index..'] drop first PING');return
        end
        local ok,reason=c.session:receive(data,ip,port,now())
        if not ok then print('[CLIENT '..index..'] ignored: '..tostring(reason)) end
    end},{max_datagram=1200}))
    local _,port=c.socket:sockname();c.port=port
    c.session=Session.new_client({session_id=c.token,now=now(),allow_insecure=true,
        peer_ip=server_ip,peer_port=server_port,rpc={request_retry_ms=20,query_retry_ms=40,retry_max_ms=120},
        send=function(data,ip,target_port,kind) return c.socket:sendto(data,ip,target_port) end})
    assert(c.session:baseline('player',1))
    clients[#clients+1],by_session[c.token]=c,c
end
local function advance_client(c)
    c.session:step(now())
    local state=c.session:take_move('player')
    if state then
        c.moved=state.motion==12
        print('[CLIENT '..c.index..'] MOVE motion='..state.motion)
    end
    if c.session:status().skipped_pauses>c.reported_skip then
        c.reported_skip=c.session:status().skipped_pauses
        print('[CLIENT '..c.index..'] skipped PAUSE v11 and acknowledged its PING')
    end
    if not c.busy then
        local event=c.session:take_notification()
        if event then
            assert(event.kind=='NOTIFY','old pause should have been skipped')
            c.busy=true
            xtimer.add(80,function() c.business_done=c.business_done+1;c.busy=false end,1)
        end
    end
    while true do
        local id,ok,result=c.session:take_result()
        if not id then break end
        c.returned=c.returned+1
        assert(id==tostring(c.returned) and ok,'RPC completion order/failure')
        local r=json.json_unpack(result)
        assert(r.session==c.token and r.owner==c.owner,'RPC result crossed sessions/workers')
        assert(r.casts==1 and r.mana==100-c.cost,'shared state or duplicate skill execution')
        print(string.format('[CLIENT %d] RESULT #%s worker=%d casts=%d mana=%d',c.index,id,r.owner,r.casts,r.mana))
    end
    if c.returned~=2 or c.business_done~=2 or not c.moved or c.reported_skip~=1 or not c.status
        or c.status.heartbeat==0 or not c.status.idle then return false end
    assert(c.dropped_request and c.dropped_ping and c.dropped_pong and c.queries>0)
    assert(c.status.casts==1 and c.status.mana==100-c.cost and c.status.received>0)
    return true
end

return {
    __init=function()
        assert(xnet.init());xtimer.init(32)
        baseline=xnet.get_stats().fd_count
        socket=assert(xnet.udp_bind(HOST,0,{on_datagram=function(_,data,ip,port)
            if done then return end
            local p=packet(data)
            local c=admit(p.session,ip,port)
            if not c then return end
            if not routes[c.token] then
                if p.kind~='HELLO' or p.version~=1 or type(p.sequence)~='number'
                    or p.sequence<1 or p.sequence>2147483647 or p.sequence%1~=0 then return end
            end
            local owner=route(c)
            if p.kind=='RPC_REQUEST' and not c.dropped_request then
                c.dropped_request=true;print('[SIM '..c.index..'] drop first RPC_REQUEST');return
            elseif p.kind=='PONG' and not c.dropped_pong then
                c.dropped_pong=true;print('[SIM '..c.index..'] drop first PONG');return
            end
            if p.kind=='RPC_QUERY' then c.queries=c.queries+1 end
            assert(xthread.post(owner,'udp_in',c.token,data,ip,port))
        end},{recv_budget=8,max_datagram=1200}))
        local ip,port=socket:sockname()
        for i=1,CLIENT_COUNT do create_client(i,ip,port) end
        assert(xnet.get_stats().udp_count==CLIENT_COUNT+1)
        assert(xnet.get_stats().fd_count==baseline+CLIENT_COUNT+1)
        print(string.format('[MAIN] ONE server UDP socket %s:%d, %d workers, %d clients',ip,port,#WORKERS,CLIENT_COUNT))
        for _,worker in ipairs(WORKERS) do
            assert(xthread.create_thread(worker,'udp-business-'..worker,'demo/xudp_protocol_main.lua'))
            started[worker]=true
        end
        xtimer.add(10000,function() finish(false,'watchdog timeout') end,1)
    end,
    __update=function()
        if done or not launched then return end
        local all=true
        for _,c in ipairs(clients) do if not advance_client(c) then all=false end end
        assert(xnet.get_stats().udp_count==CLIENT_COUNT+1,'a per-session UDP socket was created')
        if all then
            local minimum,maximum=CLIENT_COUNT,0
            for _,worker in ipairs(WORKERS) do
                local count=assignment_counts[worker] or 0
                assert(count>0,'worker received no sessions')
                minimum,maximum=math.min(minimum,count),math.max(maximum,count)
                for _,c in ipairs(clients) do
                    if c.owner==worker then assert(c.status.count==count,'worker session map differs from main') end
                end
                print(string.format('[MAIN] worker %d owns %d sessions',worker,count))
            end
            assert(maximum-minimum<=1,'round-robin distribution was not balanced')
            finish(true,string.format('one server socket, %d workers, %d isolated sessions; stable routing and send receipts',#WORKERS,CLIENT_COUNT))
        end
    end,
    __thread_handle=router.handle,
    __uninit=function()
        if not done then finish(false,'interrupted') end
        xnet.uninit()
    end,
    __tick_ms=1,
}
