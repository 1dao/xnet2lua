-- Unit specs for the xscan tokenizer module (xlua/lua_xscan.c).
-- Run via: make -C tests unit-lua ROOT=.. or bin/xnet tests/lua/xscan_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')

local C = xscan.lang({
    keywords = { 'if', 'return', 'struct' },
    ops = { '->', '>>=', '>>', '::' },
    line_comment = { '//' },
    block_comment = { { '/*', '*/' } },
    strings = { { '"', '"', escape = '\\' }, { "'", "'", escape = '\\' } },
    string_prefixes = 'LuU8',
    directive = '#',
    pp_first_branch = true,
})

local function kinds(T)
    local out = {}
    for i = 1, T.n do out[#out + 1] = T:kind(i) end
    return table.concat(out, ' ')
end

local function texts(T)
    local out = {}
    for i = 1, T.n do out[#out + 1] = T:text(i) end
    return table.concat(out, ' ')
end

spec.describe('xscan tokens', function()
    spec.it('classifies tokens and tracks lines', function()
        local T = C:tokenize('a->b /* x\ny */ >>= "s\\"t"\nif 1.5e-3')
        spec.equal(kinds(T), 'id op id op str kw num')
        spec.equal(T:text(2), '->')
        spec.equal(T:text(4), '>>=')
        spec.equal(T:text(5), '"s\\"t"')
        spec.equal(T:line(6), 3)
        spec.equal(T:text(7), '1.5e-3')
    end)

    spec.it('exposes raw arrays for hot loops', function()
        local T = C:tokenize('x = y;')
        spec.equal(T.n, 4)
        spec.equal(T.k[1], 'id')
        spec.equal(T.s[3], 5)
        spec.equal(T.e[3], 5)
        spec.equal(T.l[4], 1)
        spec.equal(T.src, 'x = y;')
    end)

    spec.it('keeps string prefixes and multi-line spans', function()
        local T = C:tokenize('L"wide" u8"x" s\n"a\\\nb"')
        spec.equal(texts(T), 'L"wide" u8"x" s "a\\\nb"')
        spec.equal(T:line(4), 2)
        spec.equal(T:eline(4), 3)
    end)

    spec.it('returns safe values outside the token range', function()
        local T = C:tokenize('a')
        spec.equal(T:text(0), '')
        spec.equal(T:text(9), '')
        spec.nil_value(T:kind(9))
        spec.equal(T:is(9, 'a'), false)
        spec.equal(T:is(1, 'a'), true)
    end)
end)

spec.describe('xscan brackets', function()
    spec.it('matches nested brackets and leaves strays unmatched', function()
        local T = C:tokenize('f(a[1]) }')
        spec.equal(T:match(2), 7)
        spec.equal(T:match(7), 2)
        spec.equal(T:match(4), 6)
        spec.nil_value(T:match(8))
        spec.nil_value(T.m[1])
    end)

    spec.it('finds call sites and bare identifiers', function()
        local T = C:tokenize('x = f(1) + g (2) + h')
        local calls = T:calls(1, T.n)
        spec.equal(#calls, 2)
        spec.equal(T:text(calls[1]), 'f')
        spec.equal(T:text(calls[2]), 'g')
        local ids = T:idents(1, T.n)
        spec.equal(#ids, 2)
        spec.equal(T:text(ids[1]), 'x')
        spec.equal(T:text(ids[2]), 'h')
    end)
end)

spec.describe('xscan preprocessor', function()
    spec.it('keeps every file-scope arm, the first arm inside brackets', function()
        local T = C:tokenize(table.concat({
            '#ifdef _WIN32',
            'int a;',
            '#else',
            'int b;',
            '#endif',
            'void f() {',
            '#ifdef X',
            '  if (x) {',
            '#else',
            '  if (y) {',
            '#endif',
            '  }',
            '}',
            '#if 0',
            'int dead;',
            '#endif',
        }, '\n'))
        local src = texts(T)
        spec.truthy(src:find('int a ;', 1, true), 'first file-scope arm kept')
        spec.truthy(src:find('int b ;', 1, true), 'second file-scope arm kept')
        spec.truthy(src:find('if ( x )', 1, true), 'first body arm kept')
        spec.truthy(not src:find('if ( y )', 1, true), 'second body arm dropped')
        spec.truthy(not src:find('dead', 1, true), '#if 0 dropped')
        -- the function's braces still pair up
        local open
        for i = 1, T.n do if T:is(i, '{') then open = i; break end end
        spec.equal(T:text(T:match(open) - 1), '}')
    end)

    spec.it('emits directives with continuations as one token', function()
        local T = C:tokenize('#define M(a) \\\n  (a + 1)\nint x;')
        spec.equal(T:kind(1), 'dir')
        spec.equal(T:eline(1), 2)
        spec.equal(T:line(2), 3)
    end)
end)

spec.describe('xscan indentation', function()
    local P = xscan.lang({
        keywords = { 'def' },
        line_comment = { '#' },
        strings = { { '"""', '"""', multiline = true }, { '"', '"', escape = '\\' } },
        indent = true,
    })

    spec.it('emits nl/indent/dedent and pairs blocks', function()
        local T = P:tokenize('a\n  b\n  # c\n\n  d\ne\n')
        spec.equal(kinds(T), 'id nl indent id nl id nl dedent id nl')
        spec.equal(T:match(3), 8)
    end)

    spec.it('ignores newlines inside brackets and closes blocks at EOF', function()
        local T = P:tokenize('def f(a,\n      b):\n    """doc\n    """\n    return')
        spec.equal(kinds(T), 'kw id op id op id op op nl indent str nl id nl dedent')
    end)
end)

spec.describe('xscan long brackets', function()
    local Lua = xscan.lang({
        keywords = { 'local', 'function', 'end' },
        ops = { '..', '...', '==', '~=' },
        line_comment = { '--' },
        strings = { { '"', '"', escape = '\\' }, { "'", "'", escape = '\\' } },
        long_brackets = true,
    })

    spec.it('reads leveled long strings as one token', function()
        local T = Lua:tokenize('local s = [==[ a ]] ]=] b\n]==] .. x')
        spec.equal(kinds(T), 'kw id op str op id')
        spec.equal(T:text(4), '[==[ a ]] ]=] b\n]==]')
        spec.equal(T:line(4), 1)
        spec.equal(T:eline(4), 2)
        spec.equal(T:line(6), 2)
    end)

    spec.it('skips long comments but keeps short ones to end of line', function()
        local T = Lua:tokenize('a --[[ x\ny ]] b\n--[=[ ]] ]=] c\n-- [[ not long\nd')
        spec.equal(texts(T), 'a b c d')
        spec.equal(T:line(2), 2)
        spec.equal(T:line(3), 3)
        spec.equal(T:line(4), 5)
    end)

    spec.it('leaves index brackets alone', function()
        local T = Lua:tokenize('t[i][ [=[k]=] ] = 1')
        spec.equal(texts(T), 't [ i ] [ [=[k]=] ] = 1')
        spec.equal(T:match(2), 4)
        spec.equal(T:match(5), 7)
    end)

    spec.it('runs an unterminated long string to the end', function()
        local T = Lua:tokenize('x = [[ open')
        spec.equal(T:kind(3), 'str')
        spec.equal(T:text(3), '[[ open')
    end)
end)

spec.describe('xscan JS literals', function()
    local JS = xscan.lang({
        keywords = { 'return', 'this', 'typeof' },
        ops = { '=>', '===', '/=' },
        line_comment = { '//' },
        block_comment = { { '/*', '*/' } },
        strings = { { '"', '"', escape = '\\' }, { "'", "'", escape = '\\' } },
        template_literals = true,
        regex_literals = true,
    })

    spec.it('reads nested template literals as one token', function()
        local T = JS:tokenize('f(`a ${ g(`x${ "}" }y`) } b\nc`, z)')
        spec.equal(kinds(T), 'id op str op id op')
        spec.equal(T:eline(3), 2)
        spec.equal(T:match(2), 6)
    end)

    spec.it('tells regex literals from division by the previous token', function()
        local T = JS:tokenize('x = a / b / c; r = /[{(]\\//g.test(s); return /}/;')
        local strs = {}
        for i = 1, T.n do if T:kind(i) == 'str' then strs[#strs + 1] = T:text(i) end end
        spec.equal(table.concat(strs, ' '), '/[{(]\\//g /}/')
        local T2 = JS:tokenize('this / 2; (a) / 2; x /= 3')
        for i = 1, T2.n do spec.truthy(T2:kind(i) ~= 'str', 'division, not regex') end
    end)

    spec.it('falls back to division when the line ends first', function()
        local T = JS:tokenize('( a\n/ b )')
        spec.equal(T:match(1), 5)
    end)
end)

spec.describe('xscan JS literal edge cases', function()
    local JS = xscan.lang({
        keywords = { 'if', 'while', 'for', 'with', 'function', 'return' },
        ops = { '=>', '===' },
        line_comment = { '//' },
        block_comment = { { '/*', '*/' } },
        strings = { { '"', '"', escape = '\\' }, { "'", "'", escape = '\\' } },
        template_literals = true,
        regex_literals = true,
    })

    spec.it('reads a regex after a control-statement condition', function()
        local T = JS:tokenize('function f(x) { if (x) /}/.test(x); while (y) /{/.exec(z); return (a) / 2 }')
        local strs = {}
        for i = 1, T.n do if T:kind(i) == 'str' then strs[#strs + 1] = T:text(i) end end
        spec.equal(table.concat(strs, ' '), '/}/ /{/')
        spec.equal(T:text(T:match(6)), '}', 'the function body still closes at the end')
        spec.equal(T:match(6), T.n)
    end)

    spec.it('skips comments inside template substitutions', function()
        local T = JS:tokenize('const x = `${1 /* { */} and ${2 // }\n}`;\nfunction g() {}')
        spec.equal(T:kind(4), 'str')
        spec.equal(T:text(6), 'function', 'the template ends before the next statement')
    end)
end)

spec.describe('xscan nesting and continuations', function()
    spec.it('nests block comments when asked (Rust)', function()
        local RS = xscan.lang({ keywords = { 'fn' }, block_comment = { { '/*', '*/' } }, nested_comments = true })
        local T = RS:tokenize('/* outer /* inner */ fn ghost() {} */\nfn real() {}')
        spec.equal(texts(T), 'fn real ( ) { }')
        spec.equal(T:line(1), 2)
        local C = xscan.lang({ keywords = { 'fn' }, block_comment = { { '/*', '*/' } } })
        spec.equal(texts(C:tokenize('/* a /* b */ x')), 'x', 'C-style comments do not nest')
    end)

    spec.it('joins Python backslash continuations into one logical line', function()
        local P = xscan.lang({ keywords = { 'def' }, line_comment = { '#' }, indent = true })
        local T = P:tokenize('def f():\n    x = 1 + \\\n        2\n    y = 3\ndef g():\n    pass\n')
        spec.equal(kinds(T), 'kw id op op op nl indent id op num op num nl id op num nl dedent kw id op op op nl indent id nl dedent')
        spec.equal(T:line(12), 3, 'line numbers keep counting across the continuation')
    end)
end)

spec.describe('xscan Rust literals', function()
    local RS = xscan.lang({
        keywords = { 'fn', 'let' },
        ops = { '->', '::' },
        line_comment = { '//' },
        strings = { { '"', '"', escape = '\\', multiline = true }, { "'", "'", escape = '\\' } },
        string_prefixes = 'bc',
        lifetimes = true,
        raw_strings = true,
    })

    spec.it('reads lifetimes as identifiers and chars as strings', function()
        local T = RS:tokenize("fn f<'a>(x: &'a str) -> char { 'x' } 'é' '\\n'")
        local lt, chars = {}, {}
        for i = 1, T.n do
            if T:kind(i) == 'id' and T:text(i):sub(1, 1) == "'" then lt[#lt + 1] = T:text(i) end
            if T:kind(i) == 'str' then chars[#chars + 1] = T:text(i) end
        end
        spec.equal(table.concat(lt, ' '), "'a 'a")
        spec.equal(table.concat(chars, ' '), "'x' 'é' '\\n'")
        spec.equal(T:match(6), 12)
    end)

    spec.it('reads hash-leveled raw strings', function()
        local T = RS:tokenize('let s = r#"a "quoted" { b"#; let t = br"x\\"; let u = r##"#"# "##;')
        local strs = {}
        for i = 1, T.n do if T:kind(i) == 'str' then strs[#strs + 1] = T:text(i) end end
        spec.equal(table.concat(strs, ' | '), 'r#"a "quoted" { b"# | br"x\\" | r##"#"# "##')
    end)
end)

local failures = spec.finish()

return {
    __init = function()
        if failures > 0 then
            os.exit(1)
        end
        xthread.stop(0)
    end,
}
