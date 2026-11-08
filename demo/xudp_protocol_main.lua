-- Run from the root: build.bat udp run-lua demo/xudp_protocol_main.lua
-- Or: make run-lua WITH_UDP=1 SCRIPT=demo/xudp_protocol_main.lua
-- Main owns ONE server UDP socket and routes whole datagrams to a worker.
-- The worker owns session/RPC/MOVE state. The client caches its second RPC.
-- Loopback simulation: fixed demo token, explicit plaintext mode, no recovery.
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
local WORKER, HOST, TOKEN = 198, '127.0.0.1', 'loopback-demo-session'
local function now() return xtimer.now_ms() end

if xthread.current_id() == WORKER then
    local server, casts, mana, empty_pings = nil, 0, 100, 0
    local next_status = 0
    local function state(version,payload)
        return {entity='player',generation=1,motion=version,sequence=1,payload=payload}
    end
    router.register('udp_in',function(data,ip,port)
        local ok,reason = server:receive(data,ip,port,now())
        if not ok then print('[WORKER] rejected datagram: '..tostring(reason)) end
    end)
    router.register('udp_sent',function(context,accepted)
        server:send_result(context,accepted,now())
    end)
    return {
        __init=function()
            xtimer.init(8)
            server=Session.new_server({session_id=TOKEN,now=now(),allow_insecure=true,
                notify={heartbeat_ms=100,retry_ms=30,retry_max_ms=120},
                send=function(data,ip,port,kind,context)
                    local empty=kind=='PING' and server.notifications.current.count==0
                    if empty then empty_pings=empty_pings+1 end
                    local ok=xthread.post(1,'udp_out',data,ip,port,kind,context)
                    if not ok then return false,'route_full' end
                    if kind=='PING' then
                        print(string.format('[WORKER] PING #%s attempt=%d empty=%s',context.id,context.attempt,tostring(empty)))
                        return nil,'pending' -- main reports actual sendto acceptance
                    end
                    return true
                end,
                dispatch=function(id,bytes)
                    local request=json.json_unpack(bytes)
                    print(string.format('[WORKER] RPC_REQUEST #%s %s',id,request.method))
                    if request.method=='cast' then
                        casts,mana=casts+1,mana-10
                        assert(server:notify('skill_started','one skill, one resource deduction'))
                        assert(server:move(state(10,'running x=10')))
                        assert(server:pause(state(11,'stopped x=11')))
                        assert(server:move(state(12,'running x=12'))) -- latest snapshot wins
                        xtimer.add(180,function()
                            assert(server:complete(id,true,json.json_pack({casts=casts,mana=mana}),now()))
                            print('[WORKER] RPC_RESULT #'..id..' saved; casts='..casts..' mana='..mana)
                        end,1)
                    elseif request.method=='inspect' then
                        assert(server.rpc.records['1'].state=='done','second RPC ran before the first completed')
                        assert(server:complete(id,true,json.json_pack({casts=casts,mana=mana}),now()))
                    else return false end
                    return true
                end})
            assert(server:notify('welcome','business thread ready'))
            assert(xthread.post(1,'worker_ready'))
        end,
        __update=function()
            local t=now()
            server:step(t)
            if t>=next_status then
                next_status=t+20
                local status=server:status()
                assert(xthread.post(1,'worker_status',casts,mana,empty_pings,
                    status.notifications.current_id==nil and status.notifications.pending==0))
            end
        end,
        __thread_handle=router.handle,
        __uninit=function() if server then server:close() end end,
        __tick_ms=1,
    }
end

local socket,client_socket,client,worker_started,baseline
local done,returned,business_done,busy,moved=false,0,0,false,false
local dropped_request,dropped_ping,dropped_pong=false,false,false
local queries,last_status,reported_skip=0,nil,0
local function finish(ok,message)
    if done then return end
    done=true
    if client then client:close() end
    if socket then socket:close() end
    if client_socket then client_socket:close() end
    if worker_started then assert(xthread.shutdown_thread(WORKER));worker_started=false end
    if baseline and xnet.get_stats().fd_count~=baseline then ok,message=false,'fd registrations leaked' end
    print('[UDP-PROTOCOL] '..(ok and 'PASS: ' or 'FAIL: ')..message)
    xthread.stop(ok and 0 or 1)
end
local function packet(data)
    local ok,p=pcall(json.json_unpack,data:sub(2))
    return ok and type(p)=='table' and p or {}
end
router.register('udp_out',function(data,ip,port,kind,context)
    if done then return end
    local accepted,reason=socket:sendto(data,ip,port)
    if kind=='PING' then assert(xthread.post(WORKER,'udp_sent',context,accepted)) end
    if not accepted then finish(false,'server sendto failed: '..tostring(reason)) end
end)
router.register('worker_ready',function()
    assert(client:rpc_call(json.json_pack({method='cast'}),now())=='1')
    assert(client:rpc_call(json.json_pack({method='inspect'}),now())=='2')
    assert(client:status().rpc_pending==1)
    print('[CLIENT] RPC #1 active, RPC #2 cached until RESULT #1')
end)
router.register('worker_status',function(casts,mana,heartbeat,idle)
    last_status={casts=casts,mana=mana,heartbeat=heartbeat,idle=idle}
end)

return {
    __init=function()
        assert(xnet.init());xtimer.init(16)
        baseline=xnet.get_stats().fd_count
        socket=assert(xnet.udp_bind(HOST,0,{on_datagram=function(_,data,ip,port)
            if done then return end
            local p=packet(data)
            if p.kind=='RPC_REQUEST' and not dropped_request then
                dropped_request=true;print('[SIM] drop first RPC_REQUEST');return
            elseif p.kind=='PONG' and not dropped_pong then
                dropped_pong=true;print('[SIM] drop first PONG');return
            end
            if p.kind=='RPC_QUERY' then queries=queries+1;print('[MAIN] route RPC_QUERY #'..p.id..' to worker') end
            assert(xthread.post(WORKER,'udp_in',data,ip,port))
        end}, {recv_budget=8,max_datagram=1200}))
        local ip,port=socket:sockname()
        client_socket=assert(xnet.udp_bind(HOST,0,{on_datagram=function(_,data,source_ip,source_port)
            if done then return end
            local p=packet(data)
            if p.kind=='PING' and not dropped_ping then
                dropped_ping=true;print('[SIM] drop first PING');return
            end
            local ok,reason=client:receive(data,source_ip,source_port,now())
            if not ok then print('[CLIENT] ignored: '..tostring(reason)) end
        end}, {max_datagram=1200}))
        client=Session.new_client({session_id=TOKEN,now=now(),allow_insecure=true,peer_ip=ip,peer_port=port,
            rpc={request_retry_ms=20,query_retry_ms=40,retry_max_ms=120},
            send=function(data,target_ip,target_port,kind)
                print('[CLIENT] send '..kind..' (business busy='..tostring(busy)..')')
                return client_socket:sendto(data,target_ip,target_port)
            end})
        assert(client:baseline('player',1))
        assert(xnet.get_stats().udp_count==2) -- one server socket + one simulated client
        print(string.format('[MAIN] one server UDP socket %s:%d; logical session belongs to worker %d',ip,port,WORKER))
        assert(xthread.create_thread(WORKER,'udp-business','demo/xudp_protocol_main.lua'))
        worker_started=true
        xtimer.add(5000,function() finish(false,'watchdog timeout') end,1)
    end,
    __update=function()
        if done then return end
        client:step(now())
        local state=client:take_move('player')
        if state then
            moved=state.motion==12
            print('[CLIENT] MOVE motion='..state.motion..' '..state.payload)
        end
        if client:status().skipped_pauses>reported_skip then
            reported_skip=client:status().skipped_pauses
            print('[CLIENT] skipped stale PAUSE v11; still acknowledged its PING')
        end
        if not busy then
            local event=client:take_notification()
            if event then
                assert(event.kind=='NOTIFY','old pause should have been skipped')
                busy=true
                print('[CLIENT] NOTIFY '..event.name..': begin serial business task')
                xtimer.add(80,function()
                    business_done=business_done+1;busy=false
                    print('[CLIENT] NOTIFY '..event.name..': business task finished')
                end,1)
            end
        end
        while true do
            local id,ok,result=client:take_result()
            if not id then break end
            returned=returned+1
            assert(id==tostring(returned) and ok,'RPC completion order/failure')
            local r=json.json_unpack(result)
            assert(r.casts==1 and r.mana==90,'duplicate skill execution or deduction')
            print('[CLIENT] RPC_RESULT #'..id..' casts='..r.casts..' mana='..r.mana)
        end
        if returned==2 and business_done==2 and moved and reported_skip==1 and last_status
            and last_status.heartbeat>0 and last_status.idle then
            assert(dropped_request and dropped_ping and dropped_pong and queries>0)
            assert(last_status.casts==1 and last_status.mana==90)
            finish(true,'RPC serialization/dedup/query, Notify, Ping/Pong, heartbeat, MOVE and stale pause')
        end
    end,
    __thread_handle=router.handle,
    __uninit=function()
        if not done then finish(false,'interrupted') end
        xnet.uninit()
    end,
    __tick_ms=1,
}
