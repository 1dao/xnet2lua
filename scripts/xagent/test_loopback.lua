-- xagent/test_loopback.lua — end-to-end SSE streaming over REAL xnet sockets,
-- no network and no API key. A loopback HTTP server emits a canned Anthropic
-- chunked text/event-stream response (split across several send_raw calls to
-- exercise incremental delivery); the client drives anthropic.stream_message
-- against it and asserts the reassembled message. Exits 0 on success, 1 on the
-- first mismatch.
--
-- Run: bin/xnet scripts/xagent/test_loopback.lua

package.path = 'scripts/?.lua;' .. package.path
local anthropic = require('xagent.llm.anthropic')
local xutils = require('xutils')

local HOST, PORT = '127.0.0.1', 18231
local BASE = string.format('http://%s:%d', HOST, PORT)

local function err(s) io.stderr:write(s .. '\n') end
local function out(s) io.write(s); io.flush() end

-- ── canned Anthropic SSE: text "Hello world" + a Read tool_use ─────────────
local function pack(t) return xutils.json_pack(t) end
local function ev(name, obj) return 'event: ' .. name .. '\ndata: ' .. pack(obj) .. '\n\n' end

local SSE = table.concat({
    ev('message_start',       { type='message_start', message={ id='msg_lb', usage={ input_tokens=7, output_tokens=0 } } }),
    ev('content_block_start',  { type='content_block_start', index=0, content_block={ type='text', text='' } }),
    ev('content_block_delta',  { type='content_block_delta', index=0, delta={ type='text_delta', text='Hello' } }),
    ev('content_block_delta',  { type='content_block_delta', index=0, delta={ type='text_delta', text=' world' } }),
    ev('content_block_stop',   { type='content_block_stop', index=0 }),
    ev('content_block_start',  { type='content_block_start', index=1, content_block={ type='tool_use', id='tu_lb', name='Read' } }),
    ev('content_block_delta',  { type='content_block_delta', index=1, delta={ type='input_json_delta', partial_json='{"file' } }),
    ev('content_block_delta',  { type='content_block_delta', index=1, delta={ type='input_json_delta', partial_json='_path":"x.lua"}' } }),
    ev('content_block_stop',   { type='content_block_stop', index=1 }),
    ev('message_delta',        { type='message_delta', delta={ stop_reason='tool_use' }, usage={ output_tokens=4 } }),
    ev('message_stop',         { type='message_stop' }),
})

-- chunk-encode `s` into pieces of `n` bytes each (HTTP Transfer-Encoding: chunked)
local function chunk_pieces(s, n)
    local pieces, i = {}, 1
    while i <= #s do
        local part = s:sub(i, i + n - 1)
        pieces[#pieces + 1] = string.format('%x\r\n%s\r\n', #part, part)
        i = i + n
    end
    pieces[#pieces + 1] = '0\r\n\r\n'
    return pieces
end

-- ── loopback server: respond once headers seen, stream the SSE in pieces ────
local server, finished
local function finish(ok, msg)
    if finished then return end
    finished = true
    out('[loopback] ' .. (ok and 'OK ' or 'FAIL ') .. tostring(msg) .. '\n')
    if server then server:close('done'); server = nil end
    xthread.stop(ok and 0 or 1)
end

local function make_server()
    local bufs = setmetatable({}, { __mode = 'k' })
    local h = {}
    function h.on_connect(conn)
        conn:set_framing({ type = 'raw', max_packet = 1024 * 1024 })
        bufs[conn] = ''
    end
    function h.on_packet(conn, data)
        local buf = (bufs[conn] or '') .. data
        if not buf:find('\r\n\r\n', 1, true) then bufs[conn] = buf; return #data end
        bufs[conn] = nil
        -- headers complete → emit a chunked SSE response in several writes
        conn:send_raw('HTTP/1.1 200 OK\r\n' ..
            'Content-Type: text/event-stream\r\n' ..
            'Transfer-Encoding: chunked\r\n' ..
            'Connection: close\r\n\r\n')
        for _, piece in ipairs(chunk_pieces(SSE, 40)) do
            conn:send_raw(piece)
        end
        conn:close('done')
        return #data
    end
    function h.on_close(conn) bufs[conn] = nil end
    return h
end

-- ── client: drive the real streaming stack ─────────────────────────────────
local streamed = {}
local tool_started
local result

local function run_client()
    anthropic.stream_message(
        { api_key = 'unused', base_url = BASE, model = 'test' },
        { messages = { { role = 'user', content = 'hi' } } },
        {
            on_text = function(t) streamed[#streamed + 1] = t end,
            on_tool_use_start = function(id, name) tool_started = name .. ':' .. id end,
            on_error = function(e) finish(false, 'on_error: ' .. tostring(e)) end,
            on_done = function(r) result = r; verify() end,
        })
end

function verify()
    local text = table.concat(streamed)
    if text ~= 'Hello world' then return finish(false, 'text=' .. text) end
    if tool_started ~= 'Read:tu_lb' then return finish(false, 'tool_started=' .. tostring(tool_started)) end
    if not result then return finish(false, 'no result') end
    if result.stop_reason ~= 'tool_use' then return finish(false, 'stop_reason=' .. tostring(result.stop_reason)) end
    local c = result.message.content
    if #c ~= 2 then return finish(false, 'blocks=' .. #c) end
    if c[1].type ~= 'text' or c[1].text ~= 'Hello world' then return finish(false, 'block1 bad') end
    if c[2].type ~= 'tool_use' or c[2].name ~= 'Read' or c[2].input.file_path ~= 'x.lua' then
        return finish(false, 'tool block bad: ' .. pack(c[2]))
    end
    if result.usage.input_tokens ~= 7 or result.usage.output_tokens ~= 4 then
        return finish(false, 'usage bad')
    end
    finish(true, 'streamed text + tool_use reassembled over real sockets')
end

local function __init()
    assert(xnet.init())
    local s, e = xnet.listen(HOST, PORT, make_server())
    if not s then return finish(false, 'listen: ' .. tostring(e)) end
    server = s
    run_client()
end

local function __uninit()
    if server then server:close('uninit'); server = nil end
    xnet.uninit()
end

return { __tick_ms = 5, __thread_handle = function() end, __init = __init, __uninit = __uninit }
