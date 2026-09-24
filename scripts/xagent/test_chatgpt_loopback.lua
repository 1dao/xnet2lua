-- Real local HTTP callback + Responses SSE transport, no external login.
package.path = 'scripts/?.lua;' .. package.path
local auth = require('xagent.auth.chatgpt')
local login = require('xagent.auth.login')
local http = dofile('scripts/core/share/xhttp_client.lua')
local responses = require('xagent.llm.responses')
local codec = dofile('scripts/core/share/xhttp_codec.lua')
local json = require('xutils')
local server, finished
local original_finish = auth.finish
local function finish(ok, message)
    if finished then return end
    finished=true;login.cancel();auth.finish=original_finish
    if server then server:close('done') end
    print((ok and 'PASS ' or 'FAIL ') .. message);xthread.stop(ok and 0 or 1)
end
local function stream_test()
    local buffers={}
    server=assert(xnet.listen('127.0.0.1',19457,{
        on_connect=function(c) c:set_framing({type='raw',max_packet=100000});buffers[c]='' end,
        on_packet=function(c,data)
            buffers[c]=(buffers[c] or '')..data
            local req=codec.parse_request(buffers[c])
            if not req then return #data end
            local body=json.json_unpack(req.body)
            if not body or body.model~='test' or not body.input or body.messages then
                finish(false,'invalid Responses request');return #data
            end
            local sse='event: response.output_text.delta\ndata: '..json.json_pack({type='response.output_text.delta',output_index=0,delta='local OK'})..'\n\n'
                ..'event: response.completed\ndata: '..json.json_pack({type='response.completed',response={id='r',output={
                    {type='message',content={{type='output_text',text='local OK'}}}},usage={input_tokens=2,output_tokens=2}}})..'\n\n'
            c:send_raw('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: '..#sse..'\r\nConnection: close\r\n\r\n'..sse)
            c:close('done');return #data
        end,
        on_close=function(c) buffers[c]=nil end,
    }))
    local text=''
    responses.stream_message({base_url='http://127.0.0.1:19457/v1',model='test',api_key='fake',max_retries=0},
        {messages={{role='user',content='hello'}}},{on_text=function(v) text=text..v end,
            on_error=function(e) finish(false,tostring(e)) end,
            on_done=function(r) finish(text=='local OK' and r.stop_reason=='end_turn','OAuth callback + Responses SSE over real sockets') end})
end
return {
    __tick_ms=20,
    __init=function()
        assert(xnet.init())
        auth.finish=function(q) assert(q.code=='fake-code');return {} end
        local url=login.start({on_done=function(ok,err)
            if not ok then finish(false,tostring(err));return end
            stream_test()
        end})
        local q=codec.parse_query(url:match('%?(.*)$'))
        local target='http://127.0.0.1:1455/auth/callback?state='..q.state..'&code=fake-code'
        http.request({url='http://127.0.0.1:1455/auth/callback?state=wrong&code=x'},function(err,r)
            if err or not r or r.status~=400 then finish(false,'bad state was not rejected');return end
            http.request({url=target},function(e) if e and not finished then finish(false,tostring(e)) end end)
        end)
    end,
    __update=function() login.tick() end,
    __uninit=function() login.cancel();xnet.uninit() end,
}
