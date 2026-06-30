-- xagent/tools/viz_publish.lua — the viz_publish tool.
--
-- Delivers a generated interactive page: writes the HTML into the viz output
-- dir, ensures the local static server is up, opens it in the browser, and
-- returns the clickable http URL. The aetherviz skill calls this instead of
-- pasting a huge HTML blob into the chat.

local fs  = dofile('scripts/core/share/xfs.lua')
local viz = require('xagent.viz')

return {
    name = 'viz_publish',
    description =
        'Publish a self-contained HTML page (an interactive visualization) to the ' ..
        'local viz site and open it in the browser. Writes the file, ensures the ' ..
        'local server is running, opens the default browser, and returns the ' ..
        'clickable http URL. Use this to DELIVER a generated page — never paste a ' ..
        'full HTML document into the chat. Pass the complete HTML in `html` and a ' ..
        'short ascii `slug` (e.g. "newtons-second-law") for the filename.',
    input_schema = {
        type = 'object',
        properties = {
            html  = { type = 'string',  description = 'The complete HTML document, from <!DOCTYPE html> to </html>.' },
            title = { type = 'string',  description = 'Human-readable page title (used for the filename when slug is omitted).' },
            slug  = { type = 'string',  description = 'Optional ascii filename slug, [a-z0-9-]. Prefer setting this for CJK titles.' },
            open  = { type = 'boolean', description = 'Open in the default browser after publishing. Default true.' },
        },
        required = { 'html' },
    },
    is_read_only = function() return false end,

    call = function(input, ctx)
        local html = input.html
        if type(html) ~= 'string' or html == '' then
            return { content = 'Error: html is required (the full HTML document).', is_error = true }
        end

        local root = viz.paths.root()
        fs.mkdirp(root)

        local fname = viz.paths.filename(input.title, input.slug)
        local fpath = root .. '/' .. fname
        local f, err = io.open(fpath, 'wb')
        if not f then
            return { content = 'Error: cannot write ' .. fpath .. ': ' .. tostring(err), is_error = true }
        end
        f:write(html); f:close()

        local port, serr = viz.ensure_server()
        local open_it = (input.open ~= false)

        local url, served
        if port then
            url = string.format('http://%s:%d/%s', viz.paths.host(), port, fname)
            served = true
        else
            -- Server unavailable (e.g. xnet built without HTTP): fall back to a
            -- file:// URL so "click to open" still works. Needs an absolute path.
            local abs = fpath
            if not abs:match('^%a:[/\\]') and not abs:match('^/') then
                local base = ctx and ctx.cwd and (tostring(ctx.cwd):gsub('[/\\]+$', ''))
                abs = base and (base .. '/' .. fpath) or fpath
            end
            url = 'file:///' .. abs:gsub('\\', '/')
            served = false
        end

        if open_it then viz.open_url.open(url) end

        local lines = {}
        lines[#lines + 1] = '✅ 已生成页面：' .. url
        lines[#lines + 1] = '文件：' .. fpath
        if served then
            lines[#lines + 1] = string.format('本地服务：http://%s:%d/ （根路径列出所有已生成页面）',
                viz.paths.host(), port)
        else
            lines[#lines + 1] = '提示：本地 HTTP 服务未启动（' .. tostring(serr) ..
                '），已退回 file:// 直接打开。'
        end
        if open_it then lines[#lines + 1] = '已在默认浏览器打开。' end
        return { content = table.concat(lines, '\n') }
    end,
}
