-- demo/router_test.lua - unit tests for xhttp_router.lua path-param support.
-- Run via:  ./demo/xnet demo/router_test.lua
-- Exits with non-zero code if any assertion fails.

local router = dofile('demo/xhttp_router.lua')

local fails = 0
local function check(ok, msg)
    if not ok then
        fails = fails + 1
        io.stderr:write('FAIL: ' .. tostring(msg) .. '\n')
    else
        print('PASS: ' .. tostring(msg))
    end
end

-- Reset to a clean slate so prior dofile state from other tests doesn't leak.
router.reset({
    not_found = function() return { status = 404, body = 'nf' } end,
})

-- Static route still works (fast path).
router.get('/hello', function(req)
    return { status = 200, body = 'hello' }
end)

-- :param route.
router.get('/users/:id', function(req)
    return { status = 200, body = 'user:' .. tostring(req.params.id) }
end)

-- Multiple :params.
router.get('/users/:uid/posts/:pid', function(req)
    return { status = 200, body = req.params.uid .. '/' .. req.params.pid }
end)

-- Wildcard.
router.get('/files/*path', function(req)
    return { status = 200, body = 'file:' .. req.params.path }
end)

-- Anonymous wildcard (-> req.params.path).
router.get('/anon/*', function(req)
    return { status = 200, body = 'anon:' .. tostring(req.params.path) }
end)

-- Method-specific (POST :param shouldn't match GET).
router.post('/users/:id', function(req)
    return { status = 200, body = 'POST user:' .. req.params.id }
end)

local function call(method, path)
    return router.handle({ method = method, path = path })
end

-- Test 1: static still hits.
do
    local r = call('GET', '/hello')
    check(r.status == 200 and r.body == 'hello', 'static GET /hello')
end

-- Test 2: :id basic.
do
    local r = call('GET', '/users/42')
    check(r.status == 200 and r.body == 'user:42', ':id binds /users/42')
end

-- Test 3: :id length mismatch (extra segment) should NOT match the :id route.
do
    local r = call('GET', '/users/42/extra')
    check(r.status == 404, '/users/42/extra should not match /users/:id')
end

-- Test 4: missing segment should not match.
do
    local r = call('GET', '/users')
    check(r.status == 404, '/users alone should not match /users/:id')
end

-- Test 5: multiple params.
do
    local r = call('GET', '/users/u9/posts/p17')
    check(r.status == 200 and r.body == 'u9/p17', 'multiple :params')
end

-- Test 6: wildcard captures rest.
do
    local r = call('GET', '/files/a/b/c.txt')
    check(r.status == 200 and r.body == 'file:a/b/c.txt', 'wildcard captures multi-segment')
end

-- Test 7: wildcard captures single segment.
do
    local r = call('GET', '/files/x.txt')
    check(r.status == 200 and r.body == 'file:x.txt', 'wildcard captures single segment')
end

-- Test 8: wildcard allows zero remaining segments (n_req == n_pat - 1).
do
    local r = call('GET', '/files')
    check(r.status == 200 and r.body == 'file:', 'wildcard allows zero remainder')
end

-- Test 9: anonymous wildcard binds to params.path.
do
    local r = call('GET', '/anon/foo/bar')
    check(r.status == 200 and r.body == 'anon:foo/bar', 'anonymous wildcard -> params.path')
end

-- Test 10: method differentiates.
do
    local r = call('POST', '/users/100')
    check(r.status == 200 and r.body == 'POST user:100', 'POST routed to :id POST handler')
end

-- Test 11: GET /users/:id should still work after POST registration.
do
    local r = call('GET', '/users/200')
    check(r.status == 200 and r.body == 'user:200', 'GET /users/:id unaffected by POST registration')
end

-- Test 12: req.params on static route is an empty table (not nil).
do
    router.reset({ not_found = function() return { status = 404 } end })
    router.get('/health', function(req)
        return { status = 200, body = type(req.params) == 'table' and 'tbl' or 'nil' }
    end)
    local r = call('GET', '/health')
    check(r.status == 200 and r.body == 'tbl', 'static route req.params defaults to {}')
end

-- Test 13: literal-after-wildcard should error at registration.
do
    router.reset({})
    local ok, err = pcall(router.get, '/a/*x/b', function() end)
    check(not ok, 'literal after wildcard should error at reg time')
end

-- Test 14: empty :param name should error.
do
    router.reset({})
    local ok = pcall(router.get, '/a/:/b', function() end)
    check(not ok, 'empty :param name should error')
end

-- Test 15: 404 path that doesn't match any pattern routes to not_found.
do
    router.reset({ not_found = function() return { status = 404, body = 'NF' } end })
    router.get('/users/:id', function() return { status = 200 } end)
    local r = call('GET', '/orders/1')
    check(r.status == 404 and r.body == 'NF', 'unmatched dyn path goes to not_found')
end

print(string.format('--- router tests: %d failures ---', fails))

-- Return a minimal thread table so xnet_main.c is happy, then stop immediately.
return {
    __init = function()
        if fails > 0 then
            io.stderr:write('TEST SUITE FAILED\n')
            os.exit(1)
        end
        xthread.stop(0)
    end,
    __update = function() end,
}
