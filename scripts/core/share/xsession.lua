-- xsession.lua -- per-fd session coroutine framework for xnet connection handlers.
--
-- Purpose
--   Replace ad-hoc "spawn coroutine per request" handling with a uniform
--   per-fd model that can be reused by HTTP / xadmin / custom binary servers.
--
-- Model
--   Every fd gets ONE long-lived "session coroutine" that processes 'rpc'-kind
--   requests serially in arrival order. Inside an rpc handler the user code
--   may freely call xthread.rpc(...) -- it yields the session co, and the C
--   layer's @async_resume intercept (see xlua/lua_xthread.c) drives it back.
--
--   'query' and 'post' kinds spawn an INDEPENDENT coroutine per request:
--     query -- has response, runs in parallel with the session co and with
--              other queries on the same fd. Response order is not preserved;
--              the application protocol must carry a request id.
--     post  -- fire-and-forget, no response written.
--
--   The default kind is 'rpc'. Apps that do not need the distinction can
--   ignore it entirely and everything funnels through the session co.
--
-- State machine (per fd)
--   cstate.state =
--     'none' -- no session co yet (lazy creation on first rpc req)
--     'idle' -- session co yielded at WAIT_NEXT, safe to resume
--     'busy' -- session co is running OR yielded inside an outgoing xthread.rpc
--              (the C @async_resume path will resume it; we MUST NOT)
--     'dead' -- session co crashed; fd will be closed
--
--   Invariant: on_packet only resumes when state == 'idle'. Anything else
--   gets enqueued; the session co picks it up on its own next loop iteration.
--
-- Close path
--   cstate.closing is set in on_close. Already queued rpc requests keep
--   draining inside the session co, but all responses are skipped because the
--   fd may no longer be sendable. Once the queue is empty the session co exits
--   cleanly. If it is yielded at WAIT_NEXT we resume it once so it can observe
--   closing. If it is yielded inside an outgoing RPC we do NOT resume; the RPC
--   reply (or timeout) will resume it naturally.
--
-- Two close-side hooks, two distinct events
--   spec.on_close(conn, reason)
--     Socket-level close notification. Fires IMMEDIATELY when xnet's close_cb
--     fires, before the session co has necessarily finished draining. Use for
--     light, best-effort actions: logging, metrics. Don't free heavy session
--     resources here -- queued/in-flight handlers may still touch them.
--
--   spec.on_session_done(conn, cstate, reason)
--     Session-drained notification. Fires EXACTLY ONCE, after both:
--       (a) spec.on_close has returned, and
--       (b) the session coroutine has fully exited (queue empty, no in-flight
--           handler, no pending outgoing xthread.rpc).
--     This is the safe point to release player/session-scoped resources.
--     Fires for every connection that had on_connect run (regardless of
--     whether a session co was ever spawned).
--     Backward compatibility: spec.on_done(conn, reason) is still supported
--     when on_session_done is not provided.
--
--   Guarantee: spec.on_close strictly precedes spec.on_session_done/on_done.
--   Even when the session co drains synchronously inside on_close (idle
--   wake-up path), the done hook is deferred until after spec.on_close returns.
--
-- Send-after-close
--   All sends go through a wrapper that checks cstate.closing/done and the fd
--   before invoking spec.send_response, so user handlers do not have to.
--
-- Parse-error policy (soft)
--   parse_packet errors do NOT close the connection on their own. on_packet:
--     1. logs the error,
--     2. calls spec.on_parse_error(conn, err) if provided (where the app can
--        send a wire-level error frame / 400, and decide whether to close),
--     3. if the parser supplied a recovery cursor (next_pos > pos), continues
--        parsing from there in the same callback,
--     4. otherwise returns data_len, discarding the rest of this batch but
--        leaving the connection alive.
--   For protocols where a parse error is fatal (HTTP), the app is expected to
--   call conn:close(reason) from inside on_parse_error.
--
-- Queue-overflow policy (soft)
--   If the rpc queue is at spec.max_queue_len when a new rpc arrives, that
--   single request is dropped and logged. No response is sent, no existing
--   queued/in-flight work is touched, and the connection stays open. Apps
--   that require backpressure visibility should ack/timeout at the protocol
--   layer (the client side decides what to do when it sees no reply).
--
-- spec.parse_packet contract
--   spec.parse_packet(data, pos, conn, cstate) returns one of:
--     req, next_pos                     -- success; next_pos MUST be in
--                                          (pos, #data + 1]
--     nil, _, 'incomplete'              -- need more bytes (also use this
--                                          when a bad frame's full extent
--                                          cannot yet be determined within
--                                          the current batch)
--     nil, next_pos, err_msg            -- recoverable error; xsession skips
--                                          to next_pos (MUST be in
--                                          (pos, #data + 1]) and keeps parsing
--     nil, nil, err_msg                 -- fatal error for this batch;
--                                          xsession drops the rest and keeps
--                                          the connection alive
--   Returning next_pos beyond #data + 1 leaves xchannel's buffer cursor
--   misaligned with the protocol stream; use 'incomplete' instead.
--
-- Dispatcher selection (per request, by priority)
--   1. spec.handle_<kind>   (explicit per-kind callable)
--   2. spec.handle          (catch-all callable)
--   3. spec.router          (xrouter -- positional convention)
--                             handler: function(arg1, arg2, ...) -> ret1, ret2, ...
--                             dispatch: stub = router.stubs[req.pt]
--                                       rets = {pcall(stub, table.unpack(req.args))}
--                             wire shape via send_response:
--                                       send_response(conn, req, ok, ret1, ret2, ...)
--   4. spec.http_router     (xhttp_router -- req-table convention)
--                             handler: function(req) -> resp
--                             dispatch: resp = http_router.handle(req)
--                             wire shape via send_response:
--                                       send_response(conn, req, resp)
--   spec.handle / spec.handle_<kind> handler signature is
--                                       function(conn, req, kind) -> resp
--   For 'post' kind: handler runs but no response is ever sent.

local M = {}

local WAIT_NEXT = '@xsession_wait_next'

local coroutine_create = coroutine.create
local coroutine_resume = coroutine.resume
local pcall            = pcall
local table_remove     = table.remove

local function log_err(prefix, fmt, ...)
    io.stderr:write(string.format('[%s] ' .. fmt, prefix, ...) .. '\n')
end

local function conn_fd(conn)
    local ok, fd = pcall(function() return conn:fd() end)
    if ok then return fd end
    return nil
end

local function conn_is_open(conn)
    local fd = conn_fd(conn)
    return type(fd) == 'number' and fd >= 0
end

local function close_conn(conn, reason)
    if not conn_is_open(conn) then return end
    local ok, err = pcall(function() return conn:close(reason) end)
    if not ok then
        io.stderr:write('[XSESSION] conn close error: ' .. tostring(err) .. '\n')
    end
end

-- Variadic safe-send: extra args after spec are forwarded to send_response.
-- Skips if the conn was closed or fd is gone. The shape of the extra args
-- depends on which dispatcher path produced them:
--   handle / http_router       -> (resp)            single resp value
--   router (xrouter positional)-> (ok, ret1, ret2,...)   ok flag + positional rets
local function safe_send(conn, cstate, req, spec, ...)
    if cstate.done or cstate.closing then return end
    if not conn_is_open(conn) then return end
    local ok, err = pcall(spec.send_response, conn, req, ...)
    if not ok then
        log_err(spec.log_prefix, 'send_response error: %s', tostring(err))
    end
end

local table_pack   = table.pack   or function(...) return { n = select('#', ...), ... } end
local table_unpack = table.unpack or unpack

-- Dispatch one request, picking the handler by priority chain:
--   handle_<kind>  >  handle  >  router  >  http_router
--
-- For 'post' kind, no response is sent regardless of handler return.
-- For 'rpc'/'query' kind:
--   * handle / http_router path: nil resp is skipped, anything else sent as-is
--   * router path: ALWAYS sends (ok, rets...) since the wire shape is fixed
local function dispatch_request(conn, cstate, req, kind, spec)
    -- Tier 1: explicit callable handlers.
    local h = (kind == 'rpc'   and spec.handle_rpc)
           or (kind == 'query' and spec.handle_query)
           or (kind == 'post'  and spec.handle_post)
           or spec.handle
    if h then
        local ok, resp = pcall(h, conn, req, kind)
        if not ok then
            log_err(spec.log_prefix, '%s handler error: %s', kind, tostring(resp))
            if spec.on_handler_error then
                pcall(spec.on_handler_error, conn, req, kind, resp)
            end
            return
        end
        if kind ~= 'post' and resp ~= nil then
            safe_send(conn, cstate, req, spec, resp)
        end
        return
    end

    -- Tier 2: spec.router (xrouter convention -- positional args/returns).
    if spec.router then
        local stubs = spec.router.stubs
        local stub  = stubs and stubs[req.pt]
        if not stub then
            if kind ~= 'post' then
                safe_send(conn, cstate, req, spec, false,
                    'unknown pt: ' .. tostring(req.pt))
            end
            return
        end
        local args  = req.args or {}
        local nargs = args.n or #args
        local rets  = table_pack(pcall(stub, table_unpack(args, 1, nargs)))
        if not rets[1] then
            log_err(spec.log_prefix, '%s router handler error pt=%s: %s',
                kind, tostring(req.pt), tostring(rets[2]))
            if spec.on_handler_error then
                pcall(spec.on_handler_error, conn, req, kind, rets[2])
            end
            if kind ~= 'post' then
                safe_send(conn, cstate, req, spec, false, tostring(rets[2]))
            end
            return
        end
        if kind ~= 'post' then
            safe_send(conn, cstate, req, spec, true,
                table_unpack(rets, 2, rets.n))
        end
        return
    end

    -- Tier 3: spec.http_router (xhttp_router convention -- function(req) -> resp).
    if spec.http_router then
        local ok, resp = pcall(spec.http_router.handle, req)
        if not ok then
            log_err(spec.log_prefix, 'http_router error: %s', tostring(resp))
            if spec.on_handler_error then
                pcall(spec.on_handler_error, conn, req, kind, resp)
            end
            return
        end
        if kind ~= 'post' and resp ~= nil then
            safe_send(conn, cstate, req, spec, resp)
        end
        return
    end

    log_err(spec.log_prefix, 'no dispatcher for kind=%s pt=%s',
        kind, tostring(req and req.pt))
end

local function classify(spec, req)
    if spec.classify then
        local k = spec.classify(req)
        if k == 'query' or k == 'post' or k == 'rpc' then return k end
    end
    if req and req.kind then
        local k = req.kind
        if k == 'query' or k == 'post' or k == 'rpc' then return k end
    end
    return 'rpc'
end

-- Fire session-done hook exactly once (guarded by cstate.on_done_fired).
-- Preferred: spec.on_session_done(conn, cstate, reason)
-- Fallback:  spec.on_done(conn, reason)
local function fire_on_done(conn, cstate, spec)
    if cstate.on_done_fired then return end
    cstate.on_done_fired = true
    local cb = spec.on_session_done or spec.on_done
    if not cb then return end
    local ok, err
    if spec.on_session_done then
        ok, err = pcall(cb, conn, cstate, cstate.last_reason)
    else
        ok, err = pcall(cb, conn, cstate.last_reason)
    end
    if not ok then
        log_err(spec.log_prefix, 'on_done error: %s', tostring(err))
    end
end

-- Transition cstate to the terminal "done" state. on_done is fired here only
-- if spec.on_close has already returned (`on_close_done` is set); otherwise
-- it is deferred to the end of handler.on_close so the on_close-then-on_done
-- ordering is preserved.
local function mark_session_done(conn, cstate, spec, reason)
    if cstate.done then return end
    cstate.state      = 'dead'
    cstate.done       = true
    cstate.session_co = nil
    cstate.last_reason = cstate.last_reason or reason
    if cstate.on_close_done then
        fire_on_done(conn, cstate, spec)
    end
end

-- Session coroutine body. Runs until the fd is closing and the queue is empty.
local function session_body(conn, cstate, spec)
    while true do
        local req = table_remove(cstate.queue, 1)
        if req then
            dispatch_request(conn, cstate, req, 'rpc', spec)
        elseif cstate.closing then
            return
        else
            cstate.state = 'idle'
            coroutine.yield(WAIT_NEXT)
            -- on resume, on_packet has set state='busy' (or on_close did)
        end
    end
end

local function spawn_session(conn, cstate, spec)
    local co = coroutine_create(function()
        local ok, err = pcall(session_body, conn, cstate, spec)
        if not ok then
            log_err(spec.log_prefix, 'session co crashed: %s', tostring(err))
            mark_session_done(conn, cstate, spec, 'session_crash')
            close_conn(conn, 'session_crash')
            return
        end
        mark_session_done(conn, cstate, spec)
    end)
    cstate.session_co = co
    cstate.state = 'busy'
    local ok, err = coroutine_resume(co)
    if not ok then
        log_err(spec.log_prefix, 'session co resume failed: %s', tostring(err))
        mark_session_done(conn, cstate, spec, 'session_resume_fail')
        close_conn(conn, 'session_resume_fail')
    end
end

local function resume_session(conn, cstate, spec)
    cstate.state = 'busy'
    local ok, err = coroutine_resume(cstate.session_co)
    if not ok then
        log_err(spec.log_prefix, 'session co resume failed: %s', tostring(err))
        mark_session_done(conn, cstate, spec, 'session_resume_fail')
        close_conn(conn, 'session_resume_fail')
    end
end

local function spawn_side(conn, cstate, req, kind, spec)
    local co = coroutine_create(function()
        dispatch_request(conn, cstate, req, kind, spec)
    end)
    local ok, err = coroutine_resume(co)
    if not ok then
        log_err(spec.log_prefix, '%s side co resume failed: %s', kind, tostring(err))
    end
end

local function dispatch(conn, cstate, req, spec)
    if cstate.done or cstate.closing then return end

    local kind = classify(spec, req)

    if kind == 'query' or kind == 'post' then
        spawn_side(conn, cstate, req, kind, spec)
        return
    end

    -- rpc path -- enqueue, then maybe nudge the session co.
    if #cstate.queue >= spec.max_queue_len then
        -- Soft-fail: keep existing queued work intact and drop only this request.
        log_err(spec.log_prefix, 'rpc queue overflow (cap=%d), dropping request pt=%s',
            spec.max_queue_len, tostring(req and req.pt))
        return
    end
    cstate.queue[#cstate.queue + 1] = req

    if cstate.state == 'none' then
        spawn_session(conn, cstate, spec)
    elseif cstate.state == 'idle' then
        resume_session(conn, cstate, spec)
    end
    -- 'busy' -- co will pop on its next loop iteration; do not resume.
    -- 'dead' -- session co already exited; the cap above drops new requests.
end

-- ---------------------------------------------------------------------------
-- Public: build a handler table suitable for xnet.attach / xnet.attach_tls.
-- ---------------------------------------------------------------------------
function M.make(spec)
    assert(type(spec) == 'table', 'xsession.make: spec must be a table')
    assert(type(spec.parse_packet) == 'function',
        'xsession.make: spec.parse_packet (data, pos, conn, cstate) -> req, next_pos, err is required')
    assert(spec.handle or spec.handle_rpc or spec.handle_query or spec.handle_post
           or spec.router or spec.http_router,
        'xsession.make: at least one dispatcher required '
        .. '(handle / handle_<kind> / router / http_router)')
    assert(spec.send_response == nil or type(spec.send_response) == 'function',
        'xsession.make: spec.send_response must be a function if provided')
    assert(spec.on_close == nil or type(spec.on_close) == 'function',
        'xsession.make: spec.on_close must be a function if provided')
    assert(spec.on_session_done == nil or type(spec.on_session_done) == 'function',
        'xsession.make: spec.on_session_done must be a function if provided')
    assert(spec.on_done == nil or type(spec.on_done) == 'function',
        'xsession.make: spec.on_done must be a function if provided')
    if spec.router then
        assert(type(spec.router) == 'table' and type(spec.router.stubs) == 'table',
            'xsession.make: spec.router must expose a .stubs table (xrouter convention)')
    end
    if spec.http_router then
        assert(type(spec.http_router) == 'table' and type(spec.http_router.handle) == 'function',
            'xsession.make: spec.http_router must expose .handle(req) (xhttp_router convention)')
    end

    spec.log_prefix    = spec.log_prefix or 'XSESSION'
    spec.max_queue_len = tonumber(spec.max_queue_len) or 1024
    if spec.connections ~= nil then
        assert(type(spec.connections) == 'table',
            'xsession.make: spec.connections must be a table if provided')
    end

    -- Default send_response if app uses only post-kind (response never sent).
    if not spec.send_response then
        spec.send_response = function(_, _, _) end
    end

    local connections = spec.connections or {}
    local handler = {}

    function handler.on_connect(conn, ip, port)
        local cstate = {
            ip             = ip,
            port           = port,
            queue          = {},
            state          = 'none',
            done           = false,
            closing        = false,
            session_co     = nil,
            last_reason    = nil,
            on_close_done  = false,  -- set true after spec.on_close returns
            on_done_fired  = false,  -- set true after spec.on_done fires once
        }
        connections[conn] = cstate

        if spec.framing then
            conn:set_framing(spec.framing)
        end

        if spec.on_connect then
            local ok, err = pcall(spec.on_connect, conn, ip, port)
            if not ok then
                log_err(spec.log_prefix, 'on_connect error: %s', tostring(err))
            end
        end
    end

    function handler.on_packet(conn, data)
        local cstate = connections[conn]
        if not cstate or cstate.done or cstate.closing then return #data end

        local pos      = 1
        local consumed = 0
        local data_len = #data

        while pos <= data_len do
            local req, next_pos, err = spec.parse_packet(data, pos, conn, cstate)
            if req then
                dispatch(conn, cstate, req, spec)

                -- Defensive: parser must advance pos on success. If it didn't,
                -- bail out of this batch instead of spinning forever.
                local advance = next_pos or (pos + 1)
                if advance <= pos then
                    log_err(spec.log_prefix,
                        'parse_packet returned non-advancing next_pos=%s on success pt=%s',
                        tostring(next_pos), tostring(req.pt))
                    return data_len
                end
                consumed = advance - 1
                pos      = advance

                -- on_packet ran user handlers via dispatch; if any of them
                -- closed the conn synchronously (on_close already ran),
                -- stop parsing further frames from this batch.
                if cstate.done or cstate.closing then break end
            else
                if err == 'incomplete' then break end

                -- Parse error policy: report, then discard bad input instead of
                -- forcing connection close. If parser can provide a recovery
                -- cursor (next_pos > pos), continue from there; otherwise drop
                -- the remaining bytes of this callback batch.
                log_err(spec.log_prefix, 'parse error: %s', tostring(err))
                if spec.on_parse_error then
                    pcall(spec.on_parse_error, conn, err)
                end
                -- on_parse_error may itself have closed the conn (e.g. HTTP
                -- worker explicitly closes after sending 400). Stop parsing.
                if cstate.done or cstate.closing then return data_len end
                if next_pos and next_pos > pos then
                    consumed = next_pos - 1
                    pos = next_pos
                else
                    return data_len
                end
            end
        end

        return consumed
    end

    -- Close every live connection this handler is tracking.
    -- Useful for `__uninit` paths and for stop-style xthread messages.
    function handler.close_all(reason)
        reason = reason or 'close_all'
        local list = {}
        for conn in pairs(connections) do
            list[#list + 1] = conn
        end
        for i = 1, #list do
            close_conn(list[i], reason)
        end
    end

    function handler.on_close(conn, reason)
        local cstate = connections[conn]
        connections[conn] = nil
        if not cstate then
            -- on_connect never ran (or already cleaned). Best-effort hooks.
            if spec.on_close then pcall(spec.on_close, conn, reason) end
            return
        end

        cstate.closing     = true
        cstate.last_reason = cstate.last_reason or reason

        -- Wake an idle session co so it can observe closing and exit cleanly.
        -- Busy session co (handler running OR yielded inside outgoing RPC)
        -- exits on its own when control returns to session_body's while loop.
        --
        -- mark_session_done checks cstate.on_close_done before firing on_done,
        -- so any synchronous drain triggered below WON'T cross-fire on_done
        -- before spec.on_close runs.
        if cstate.session_co and cstate.state == 'idle' then
            resume_session(conn, cstate, spec)
        elseif not cstate.session_co then
            cstate.state = 'dead'
            cstate.done  = true
        end

        -- Tier 1 hook: socket-level close. May fire while session co is still
        -- draining (busy / yielded-on-rpc cases).
        if spec.on_close then
            local ok, err = pcall(spec.on_close, conn, reason)
            if not ok then
                log_err(spec.log_prefix, 'on_close error: %s', tostring(err))
            end
        end

        -- Tier 2 hook: lifecycle. on_close has now returned; if the session co
        -- already exited (idle-drain or never-spawned paths), fire on_done
        -- now. Otherwise it'll fire from mark_session_done when the co exits
        -- asynchronously (busy / rpc-yielded paths).
        cstate.on_close_done = true
        if cstate.done then
            fire_on_done(conn, cstate, spec)
        end
    end

    return handler
end

return M
