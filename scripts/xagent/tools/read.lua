-- xagent/tools/read.lua — the Read tool. Reads a file with cat -n line numbers.
-- (Text path; images deferred.)

local path = dofile('scripts/core/share/xpath.lua')
local text = dofile('scripts/core/share/xtext.lua')

local MAX_LINE_LEN = 2000     -- guard against pathological single-line files

local function add_line_numbers(lines, start_line)
    local out = {}
    local maxn = start_line + #lines - 1
    local width = #tostring(maxn)
    for i, line in ipairs(lines) do
        if #line > MAX_LINE_LEN then line = line:sub(1, MAX_LINE_LEN) .. '...[line truncated]' end
        out[i] = string.format('%' .. width .. 'd\t%s', start_line + i - 1, line)
    end
    return table.concat(out, '\n')
end

return {
    name = 'Read',
    description =
        'Read the contents of a file at the given path. Use offset and limit to ' ..
        'read specific line ranges of large files. Output includes line numbers ' ..
        'in cat -n format.',
    input_schema = {
        type = 'object',
        properties = {
            file_path = { type = 'string', description = 'Absolute or relative path to the file' },
            offset = { type = 'number', description = '1-indexed start line (default 1)' },
            limit = { type = 'number', description = 'Number of lines to read (default: all)' },
        },
        required = { 'file_path' },
    },
    is_read_only = function() return true end,
    is_concurrency_safe = function() return true end,

    call = function(input, ctx)
        local fp = input.file_path
        if type(fp) ~= 'string' or fp == '' then
            return { content = 'Error: file_path is required', is_error = true }
        end
        local resolved = path.resolve(fp, ctx and ctx.cwd)

        local f, err = io.open(resolved, 'rb')
        if not f then
            return { content = 'Error: cannot open ' .. resolved .. ': ' .. tostring(err), is_error = true }
        end
        local data = f:read('*a') or ''
        f:close()

        local all = text.split_lines(data)
        local total = #all
        local offset = math.max(1, math.floor(tonumber(input.offset) or 1))
        local limit = tonumber(input.limit)
        local last = limit and math.min(total, offset + math.floor(limit) - 1) or total

        local selected = {}
        for i = offset, last do selected[#selected + 1] = all[i] end

        local range = (offset > 1 or last < total)
            and string.format(' (lines %d-%d of %d)', offset, last, total)
            or string.format(' (%d lines)', total)

        local body = #selected > 0 and add_line_numbers(selected, offset) or '(empty selection)'
        return { content = resolved .. range .. '\n' .. body }
    end,
}
