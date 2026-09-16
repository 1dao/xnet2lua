-- xagent/test_tools_shell.lua — end-to-end checks for the tools that shell out
-- (Bash, Grep). These were previously only covered by live agent runs, which is
-- why a quoting bug in Grep could sit unnoticed: it built its command by wrapping
-- each argument in double quotes, and a POSIX shell looks inside those.
--
-- Run: bin/xnet scripts/xagent/test_tools_shell.lua
-- Requires: ripgrep (rg) on PATH for the Grep cases.

package.path = 'scripts/?.lua;' .. package.path
local router = dofile('scripts/core/share/xrouter.lua')
local xutils = require('xutils')
local subprocess = require('xagent.proc.subprocess')
local bash = require('xagent.tools.bash')
local grep = require('xagent.tools.grep')

local IS_WIN = (package.config:sub(1, 1) == '\\')
local function out(s) io.write(s); io.flush() end

-- A file whose contents are exactly the shell metacharacters that used to be
-- interpreted instead of searched for.
local FIXTURE_DIR  = 'tmp'
local FIXTURE      = FIXTURE_DIR .. '/shell_quote_fixture.txt'
local PAYLOAD      = 'marker $(echo PWNED) and `echo ALSOPWNED` and $HOME done'

local function write_fixture()
    xutils.mkdir_p(FIXTURE_DIR)
    local f = assert(io.open(FIXTURE, 'wb'))
    f:write(PAYLOAD .. '\n')
    f:close()
end

local function run_tests()
    local fails = 0
    local function check(name, cond, detail)
        if cond then out('PASS ' .. name .. '\n')
        else fails = fails + 1; out('FAIL ' .. name .. ' :: ' .. tostring(detail) .. '\n') end
    end

    local ctx = { cwd = xutils.cwd() }

    -- ---------------------------------------------------------------- Bash ---
    local b1 = bash.call({ command = 'echo bash-tool-ok' }, ctx)
    check('Bash echo', not b1.is_error and b1.content:find('bash-tool-ok', 1, true) ~= nil,
        tostring(b1.content))

    local b2 = bash.call({ command = 'this_command_does_not_exist_xyz123' }, ctx)
    check('Bash nonzero exit is an error', b2.is_error == true, tostring(b2.content))
    check('Bash reports the exit code',
        tostring(b2.content):find('exit code:', 1, true) ~= nil, tostring(b2.content))

    local b3 = bash.call({ command = '' }, ctx)
    check('Bash rejects an empty command', b3.is_error == true, tostring(b3.content))

    -- Quotes inside a Bash command survive: the command string is handed to the
    -- shell as-is, which is the tool's contract.
    local b4 = bash.call({ command = 'echo "a b c"' }, ctx)
    check('Bash keeps quoted spacing',
        tostring(b4.content):find('a b c', 1, true) ~= nil, tostring(b4.content))

    -- ---------------------------------------------------------------- Grep ---
    -- rg is an external dependency, not part of this repo. Report the Grep cases
    -- as skipped where it is missing rather than as seven identical failures.
    local probe = subprocess.run({ argv = { 'rg', '--version' }, timeout_ms = 10000 })
    if probe.exit_code ~= 0 then
        out('SKIP Grep cases (ripgrep not on PATH)\n')
        out(string.format('\n[tools-shell] %s (%d failures, Grep skipped)\n',
            fails == 0 and 'ALL PASS' or 'FAILED', fails))
        os.remove(FIXTURE)
        xthread.stop(fails == 0 and 0 or 1)
        return
    end

    local g1 = grep.call({ pattern = 'proc_exec', path = 'scripts/core/server' }, ctx)
    check('Grep finds a known symbol',
        not g1.is_error and g1.content:find('xproc', 1, true) ~= nil, tostring(g1.content))
    check('Grep output has file:line prefixes',
        tostring(g1.content):find('%.lua:%d+:') ~= nil, tostring(g1.content))

    -- Assembled at runtime so the literal never appears in this file — Grep
    -- searches the whole workspace, this file included, and a spelled-out
    -- "no such string" would match itself.
    local absent = 'zzz' .. '_absent_' .. 'marker' .. '_zzz'
    local g2 = grep.call({ pattern = absent }, ctx)
    check('Grep reports no matches', g2.content == 'No matches found.', tostring(g2.content))

    local g3 = grep.call({ pattern = 'proc_exec', glob = '*.md', path = 'scripts' }, ctx)
    check('Grep honours glob', g3.content == 'No matches found.', tostring(g3.content))

    -- THE REGRESSION TEST. The pattern contains $( ) and a backtick. Quoted
    -- properly it reaches rg verbatim and matches the fixture; wrapped in double
    -- quotes, a POSIX shell would run `echo PWNED` first and rg would search for
    -- something else entirely (and on Windows the old escaping was no better).
    local g4 = grep.call({ pattern = [[\$\(echo PWNED\)]], path = FIXTURE }, ctx)
    check('Grep passes $( ) through literally',
        not g4.is_error and g4.content:find('marker', 1, true) ~= nil, tostring(g4.content))

    local g5 = grep.call({ pattern = '`echo ALSOPWNED`', path = FIXTURE }, ctx)
    check('Grep passes backticks through literally',
        not g5.is_error and g5.content:find('marker', 1, true) ~= nil, tostring(g5.content))

    local g6 = grep.call({ pattern = [[\$HOME]], path = FIXTURE }, ctx)
    check('Grep does not expand $HOME',
        not g6.is_error and g6.content:find('marker', 1, true) ~= nil, tostring(g6.content))

    local g7 = grep.call({ pattern = 'x' }, { cwd = nil })
    check('Grep runs without a ctx cwd', g7 ~= nil and g7.content ~= nil, 'no result')

    -- %VAR% has no safe representation through cmd /c, so on Windows it is
    -- refused rather than silently searched for as something else.
    if IS_WIN then
        local g8 = grep.call({ pattern = 'see %PATH% here', path = FIXTURE }, ctx)
        check('Grep refuses %VAR% on Windows', g8.is_error == true, tostring(g8.content))
    end

    os.remove(FIXTURE)
    out(string.format('\n[tools-shell] %s (%d failures)\n',
        fails == 0 and 'ALL PASS' or 'FAILED', fails))
    xthread.stop(fails == 0 and 0 or 1)
end

local function __init()
    local ok, err = subprocess.setup()
    if not ok then out('setup failed: ' .. tostring(err) .. '\n'); xthread.stop(2); return end
    write_fixture()
    local co = coroutine.create(run_tests)
    local rok, rerr = coroutine.resume(co)
    if not rok then io.stderr:write('test coroutine error: ' .. tostring(rerr) .. '\n'); xthread.stop(1) end
end

return {
    __thread_handle = router.handle,
    __init = __init,
    __uninit = function()
        -- Join the process workers while this state is still alive (see xproc.shutdown).
        subprocess.shutdown()
    end,
}
