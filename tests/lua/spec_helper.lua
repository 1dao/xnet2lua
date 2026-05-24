local M = {
    total = 0,
    failed = 0,
    failures = {},
}

local function fail(message)
    error(message, 3)
end

function M.describe(name, fn)
    print('\n== ' .. tostring(name) .. ' ==')
    fn()
end

function M.it(name, fn)
    M.total = M.total + 1
    local ok, err = pcall(fn)
    if ok then
        print('PASS ' .. tostring(name))
    else
        M.failed = M.failed + 1
        local msg = 'FAIL ' .. tostring(name) .. ': ' .. tostring(err)
        M.failures[#M.failures + 1] = msg
        io.stderr:write(msg .. '\n')
    end
end

function M.equal(got, want, message)
    if got ~= want then
        fail((message or 'values differ') ..
            string.format(' (got=%s, want=%s)', tostring(got), tostring(want)))
    end
end

function M.truthy(value, message)
    if not value then
        fail(message or 'expected truthy value')
    end
end

function M.nil_value(value, message)
    if value ~= nil then
        fail((message or 'expected nil') .. ' (got=' .. tostring(value) .. ')')
    end
end

function M.contains(text, needle, message)
    text = tostring(text or '')
    needle = tostring(needle or '')
    if not text:find(needle, 1, true) then
        fail((message or 'text does not contain needle') ..
            string.format(' (needle=%s, text=%s)', needle, text))
    end
end

function M.finish()
    print('\n========================================')
    print(string.format('Lua unit tests: %d passed, %d failed',
        M.total - M.failed, M.failed))
    if M.failed > 0 then
        for _, msg in ipairs(M.failures) do
            print(msg)
        end
    end
    print('========================================')
    return M.failed
end

return M
