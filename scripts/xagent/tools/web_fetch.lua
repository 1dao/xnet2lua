-- xagent/tools/web_fetch.lua — fetch a URL and return its text content.
-- Uses the shared async HTTP/HTTPS client (follows redirects, gunzips); strips
-- HTML to readable text. MUST run inside the agent coroutine (await). The
-- `prompt` is advisory — the main model reads the returned text.

local async = dofile('scripts/core/share/xasync.lua')
local text = dofile('scripts/core/share/xtext.lua')
local httpc = dofile('scripts/core/share/xhttp_client.lua')

local MAX_OUTPUT = 30000
local UA = 'Mozilla/5.0 (compatible; xagent/0.1)'

-- Best-effort HTML → text: drop script/style blocks, strip tags, decode common
-- entities, collapse whitespace.
local function html_to_text(html)
    html = tostring(html or '')
    -- remove <script>…</script> / <style>…</style> (case-insensitive scan)
    local lower = html:lower()
    for _, tag in ipairs({ 'script', 'style' }) do
        local open = '<' .. tag
        while true do
            local s = lower:find(open, 1, true)
            if not s then break end
            local e = lower:find('</' .. tag .. '>', s, true)
            if not e then e = #lower - #('</' .. tag .. '>') + 1 end
            local stop = (lower:find('</' .. tag .. '>', s, true) and (e + #('</' .. tag .. '>') - 1)) or #html
            html = html:sub(1, s - 1) .. ' ' .. html:sub(stop + 1)
            lower = html:lower()
        end
    end
    local t = html:gsub('<[^>]*>', ' ')
    t = t:gsub('&nbsp;', ' '):gsub('&amp;', '&'):gsub('&lt;', '<'):gsub('&gt;', '>')
         :gsub('&quot;', '"'):gsub('&#39;', "'")
         :gsub('&#(%d+);', function(n) local c = tonumber(n); return c and utf8.char(c) or '' end)
    t = t:gsub('[ \t]+', ' '):gsub('%s*\n%s*', '\n'):gsub('\n\n+', '\n\n')
    return text.valid_utf8((t:gsub('^%s+', ''):gsub('%s+$', '')))
end

return {
    name = 'WebFetch',
    description =
        'Fetch a URL over HTTP(S) and return its text content (HTML is stripped ' ..
        'to readable text). Use to read docs/pages. `prompt` describes what you ' ..
        'are looking for.',
    input_schema = {
        type = 'object',
        properties = {
            url = { type = 'string', description = 'The URL to fetch (http or https)' },
            prompt = { type = 'string', description = 'What to look for in the page' },
        },
        required = { 'url' },
    },
    is_read_only = function() return true end,

    call = function(input)
        local url = input.url
        if type(url) ~= 'string' or not url:match('^https?://') then
            return { content = 'Error: a http(s) url is required', is_error = true }
        end

        local err, resp = async.await(function(resolve)
            httpc.get(url, { timeout_ms = 20000, headers = { ['User-Agent'] = UA } },
                function(e, r) resolve(e, r) end)
        end)
        if err then
            return { content = 'Error fetching ' .. url .. ': ' .. tostring(err), is_error = true }
        end

        local ctype = (resp.headers and (resp.headers['content-type'] or '')) or ''
        local body = resp.body or ''
        local out = ctype:find('html', 1, true) and html_to_text(body) or text.valid_utf8(body)
        out = text.truncate(out, MAX_OUTPUT)
        return { content = string.format('Fetched %s (HTTP %s, %d bytes):\n%s',
            url, tostring(resp.status), #body, out) }
    end,
}
