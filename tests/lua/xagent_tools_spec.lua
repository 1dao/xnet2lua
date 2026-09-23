-- Unit specs for the offline-testable xagent tool logic: edit_core (apply_edit /
-- preview), glob_match (glob → pattern), and path helpers. The tools that do I/O
-- or shell out (Read/Write/Bash/LS/Glob/Grep) are exercised by live agent runs.
-- Run via: bin/xnet tests/lua/xagent_tools_spec.lua

package.path = 'scripts/?.lua;' .. package.path

local spec = dofile('tests/lua/spec_helper.lua')
local edit_core = require('xagent.tools.edit_core')
local globm = dofile('scripts/core/share/xglob.lua')
local path = dofile('scripts/core/share/xpath.lua')
local transcript = require('xagent.ui.transcript')   -- M.wrap is pure (no raygui)
local markdown = require('xagent.ui.markdown')
local text = dofile('scripts/core/share/xtext.lua')

spec.describe('edit_core.apply_edit', function()
    spec.it('replaces a unique occurrence', function()
        local r = edit_core.apply_edit('local x = 1\nreturn x\n',
            { old_string = 'local x = 1', new_string = 'local x = 2' })
        spec.equal(r.replacements, 1)
        spec.equal(r.content, 'local x = 2\nreturn x\n')
    end)

    spec.it('errors when old_string is not found', function()
        local ok, err = pcall(edit_core.apply_edit, 'abc', { old_string = 'zzz', new_string = 'y' })
        spec.equal(ok, false)
        spec.contains(err, 'not found')
    end)

    spec.it('errors on a non-unique match without replace_all', function()
        local ok, err = pcall(edit_core.apply_edit, 'a a a', { old_string = 'a', new_string = 'b' })
        spec.equal(ok, false)
        spec.contains(err, 'not unique')
    end)

    spec.it('replace_all replaces every occurrence', function()
        local r = edit_core.apply_edit('a a a', { old_string = 'a', new_string = 'b', replace_all = true })
        spec.equal(r.replacements, 3)
        spec.equal(r.content, 'b b b')
    end)

    spec.it('treats old_string literally (no Lua pattern magic)', function()
        local r = edit_core.apply_edit('value = obj.field',
            { old_string = 'obj.field', new_string = 'obj.other' })
        spec.equal(r.content, 'value = obj.other')
    end)

    spec.it('rejects empty / identical strings', function()
        spec.equal((pcall(edit_core.apply_edit, 'x', { old_string = '', new_string = 'y' })), false)
        spec.equal((pcall(edit_core.apply_edit, 'x', { old_string = 'x', new_string = 'x' })), false)
    end)

    -- The Read tool LF-normalizes what the model sees, so an old_string copied
    -- from a CRLF file arrives as LF. The match must still succeed against the
    -- raw \r\n bytes, and the replacement must keep the file's CRLF endings.
    spec.it('matches an LF old_string against a CRLF file (multi-line)', function()
        local crlf = 'line1\r\nline2\r\nline3\r\n'
        local r = edit_core.apply_edit(crlf,
            { old_string = 'line1\nline2', new_string = 'lineA\nlineB' })
        spec.equal(r.replacements, 1)
        spec.equal(r.content, 'lineA\r\nlineB\r\nline3\r\n')   -- inserted text is CRLF too
    end)

    spec.it('keeps CRLF endings on a single-line edit in a CRLF file', function()
        local r = edit_core.apply_edit('#include <malloc.h>\r\nint main(){}\r\n',
            { old_string = 'malloc.h', new_string = 'stdlib.h' })
        spec.equal(r.content, '#include <stdlib.h>\r\nint main(){}\r\n')
    end)

    spec.it('matches a CRLF old_string against an LF file (reverse case)', function()
        local r = edit_core.apply_edit('a\nb\nc\n',
            { old_string = 'a\r\nb', new_string = 'x\r\ny' })
        spec.equal(r.content, 'x\ny\nc\n')                     -- normalized to the file's LF
    end)

    spec.it('still errors when the text is genuinely absent in a CRLF file', function()
        local ok, err = pcall(edit_core.apply_edit, 'line1\r\nline2\r\n',
            { old_string = 'nope\nmissing', new_string = 'y' })
        spec.equal(ok, false)
        spec.contains(err, 'not found')
    end)
end)

spec.describe('glob_match', function()
    spec.it('* stays within a path segment', function()
        spec.truthy(globm.match('*.lua', 'sse.lua'))
        spec.equal(globm.match('*.lua', 'llm/sse.lua'), false)
    end)

    spec.it('** crosses path separators', function()
        spec.truthy(globm.match('**/*.lua', 'a/b/sse.lua'))
        spec.truthy(globm.match('**/*.lua', 'sse.lua'))
        spec.truthy(globm.match('scripts/**/*.lua', 'scripts/xagent/llm/sse.lua'))
    end)

    spec.it('? matches exactly one non-slash char', function()
        spec.truthy(globm.match('a?c', 'abc'))
        spec.equal(globm.match('a?c', 'a/c'), false)
    end)

    spec.it('normalizes backslashes and is anchored', function()
        spec.truthy(globm.match('llm/*.lua', 'llm\\sse.lua'))
        spec.equal(globm.match('*.lua', 'sse.luax'), false)
    end)
end)

spec.describe('path helpers', function()
    spec.it('detects absolute paths cross-platform', function()
        spec.truthy(path.is_absolute('/etc/hosts'))
        spec.truthy(path.is_absolute('C:/src/x'))
        spec.truthy(path.is_absolute('C:\\src\\x'))
        spec.equal(path.is_absolute('rel/path'), false)
    end)

    spec.it('resolves relative against cwd, leaves absolute alone', function()
        spec.equal(path.resolve('a/b', '/root'), '/root/a/b')
        spec.equal(path.resolve('a/b', '/root/'), '/root/a/b')
        spec.equal(path.resolve('/abs', '/root'), '/abs')
    end)
end)

spec.describe('transcript.wrap', function()
    -- 10px per codepoint, so max_width N*10 fits N chars per line.
    local measure = function(s) return (utf8.len(s) or #s) * 10 end

    spec.it('keeps a short line on one row', function()
        local lines = transcript.wrap('hello', 1000, measure)
        spec.equal(#lines, 1)
        spec.equal(lines[1], 'hello')
    end)

    spec.it('wraps at word boundaries', function()
        local lines = transcript.wrap('aaa bbb ccc', 70, measure)   -- "aaa bbb"=70 fits
        spec.equal(#lines, 2)
        spec.equal(lines[1], 'aaa bbb')
        spec.equal(lines[2], 'ccc')
    end)

    spec.it('breaks CJK runs per character (no spaces)', function()
        local lines = transcript.wrap('你好世界朋友', 30, measure)   -- 3 chars/line
        spec.equal(#lines, 2)
        spec.equal(lines[1], '你好世')
        spec.equal(lines[2], '界朋友')
    end)

    spec.it('preserves explicit newlines', function()
        local lines = transcript.wrap('a\nb', 1000, measure)
        spec.equal(#lines, 2)
        spec.equal(lines[1], 'a')
        spec.equal(lines[2], 'b')
    end)
end)

spec.describe('markdown', function()
    local P = markdown.palette

    spec.it('strips inline markup to visible text', function()
        spec.equal(markdown.strip_inline('a **bold** b'), 'a bold b')
        spec.equal(markdown.strip_inline('use `signal()` now'), 'use signal() now')
        spec.equal(markdown.strip_inline('see [docs](http://x)'), 'see docs')
    end)

    spec.it('colors headings and strips the hashes', function()
        local out = markdown.render('## Hello world')
        spec.equal(#out, 1)
        spec.equal(out[1].text, 'Hello world')
        spec.equal(out[1].color, P.heading)
    end)

    spec.it('renders fenced code with a background, fences hidden', function()
        local out = markdown.render('```lua\nlocal x = 1\n```')
        spec.equal(#out, 1)                 -- only the code line; both fences hidden
        spec.equal(out[1].text, 'local x = 1')
        spec.truthy(out[1].bg)
        spec.equal(out[1].color, P.code)
    end)

    spec.it('turns list markers into bullets', function()
        local out = markdown.render('- first\n- second')
        spec.equal(out[1].text, '• first')
        spec.equal(out[2].text, '• second')
        spec.equal(out[1].color, P.bullet)
    end)

    spec.it('keeps table pipes and body text', function()
        local out = markdown.render('| a | b |\nplain line')
        spec.equal(out[1].text, '| a | b |')
        spec.equal(out[1].color, P.table)
        spec.equal(out[2].text, 'plain line')
        spec.equal(out[2].color, P.text)
    end)
end)

spec.describe('text.valid_utf8', function()
    local FFFD = '\239\191\189'

    spec.it('leaves valid UTF-8 untouched', function()
        spec.equal(text.valid_utf8('hello 世界 ✅'), 'hello 世界 ✅')
    end)

    spec.it('replaces a stray high byte with U+FFFD', function()
        spec.equal(text.valid_utf8('a\255b'), 'a' .. FFFD .. 'b')
    end)

    spec.it('replaces an incomplete trailing multibyte sequence', function()
        -- 0xE4 0xB8 starts a 3-byte char but is missing its 3rd byte
        spec.equal(text.valid_utf8('x\228\184'), 'x' .. FFFD .. FFFD)
    end)

    spec.it('result is round-trippable through json_pack (no nil body)', function()
        local xutils = require('xutils')
        local body = xutils.json_pack({ s = text.valid_utf8('bad\255bytes') })
        spec.truthy(body and #body > 0, 'json_pack produced a non-empty body')
    end)
end)

spec.describe('text.head_tail', function()
    spec.it('returns short input unchanged', function()
        spec.equal(text.head_tail('abc', 10, 10), 'abc')
    end)

    spec.it('keeps both ends on line boundaries and counts the gap', function()
        local lines = {}
        for i = 1, 200 do lines[i] = string.format('line %03d', i) end
        local s = table.concat(lines, '\n')
        local out = text.head_tail(s, 100, 100)
        spec.truthy(out:sub(1, 8) == 'line 001', 'head kept')
        spec.truthy(out:sub(-8) == 'line 200', 'tail kept')
        spec.truthy(not out:find('line 100', 1, true), 'middle dropped')
        spec.contains(out, 'bytes omitted')
        for row in out:gmatch('[^\n]+') do
            spec.truthy(row:match('^line %d%d%d$') or row:match('^%.%.%.%[%d+ bytes omitted%]%.%.%.$'),
                'no partial line: ' .. row)
        end
    end)

    spec.it('never splits a UTF-8 sequence', function()
        local s = string.rep('中', 100)          -- 3 bytes each, no newlines
        local out = text.head_tail(s, 10, 10)
        spec.equal(text.valid_utf8(out), out)
    end)
end)

spec.describe('Read tool', function()
    local read = require('xagent.tools.read')
    local tmp = (os.getenv('TEMP') or os.getenv('TMPDIR') or '.') .. '/xagent_read_spec.txt'
    local function write_lines(n, width)
        local rows = {}
        for i = 1, n do
            local r = 'row' .. i
            rows[i] = r .. string.rep(' ', (width or 0) - #r)
        end
        local f = assert(io.open(tmp, 'wb')); f:write(table.concat(rows, '\n')); f:close()
    end

    spec.it('reads a small file whole with no continuation footer', function()
        write_lines(5)
        local r = read.call({ file_path = tmp })
        spec.contains(r.content, '(5 lines)')
        spec.contains(r.content, 'row5')
        spec.truthy(not r.content:find('Call Read with offset', 1, true))
    end)

    spec.it('defaults to 2000 lines and names the next offset', function()
        write_lines(2500)
        local r = read.call({ file_path = tmp })
        spec.contains(r.content, 'row2000')
        spec.truthy(not r.content:find('row2001', 1, true), 'stops at the default limit')
        spec.contains(r.content, 'Call Read with offset=2001')
    end)

    spec.it('caps the window at ~50KB on a whole line, even with an explicit limit', function()
        write_lines(2000, 100)                    -- ~200KB
        local r = read.call({ file_path = tmp, limit = 2000 })
        spec.truthy(#r.content < 52000, 'got ' .. #r.content .. ' bytes')
        local next_off = tonumber(r.content:match('offset=(%d+) to continue'))
        spec.truthy(next_off and next_off > 1, 'footer gives the next offset')
        spec.contains(r.content, 'cut at ~50KB')
        spec.contains(r.content, 'row' .. (next_off - 1))
    end)

    spec.it('honors an explicit offset and reports past-the-end reads', function()
        write_lines(10)
        spec.contains(read.call({ file_path = tmp, offset = 8 }).content, 'row10')
        spec.contains(read.call({ file_path = tmp, offset = 50 }).content, 'past the end')
        os.remove(tmp)
    end)
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
