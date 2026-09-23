-- xagent/tools/read.lua — the Read tool. Reads a file with cat -n line numbers.
-- (Text path; images deferred.)

local path = dofile('scripts/core/share/xpath.lua')
local text = dofile('scripts/core/share/xtext.lua')

local MAX_LINE_LEN = 2000     -- guard against pathological single-line files
-- A read stays in the history and is resent on every later turn, so one call
-- returns a bounded window. DEFAULT_LIMIT applies when the model gives no
-- limit; MAX_BYTES caps any window (an explicit limit included) and is cut on
-- a whole line. The footer names the next offset, so a cut read is never
-- mistaken for the whole file.
local DEFAULT_LIMIT = 2000
local MAX_BYTES = 50000

-- Number lines[1..] from start_line until the byte budget runs out.
-- Returns (text, count_shown); always shows at least one line.
local function add_line_numbers(lines, start_line)
    local out = {}
    local maxn = start_line + #lines - 1
    local width = #tostring(maxn)
    local used = 0
    for i, line in ipairs(lines) do
        if #line > MAX_LINE_LEN then line = line:sub(1, MAX_LINE_LEN) .. '...[line truncated]' end
        local row = string.format('%' .. width .. 'd\t%s', start_line + i - 1, line)
        if i > 1 and used + #row + 1 > MAX_BYTES then break end
        used = used + #row + 1
        out[i] = row
    end
    return table.concat(out, '\n'), #out
end

return {
    name = 'Read',
    description =
        'Read the contents of a file at the given path. Returns up to 2000 lines ' ..
        '(~50KB) per call; a footer gives the offset to continue from when more ' ..
        'remains. For large files, use offset and limit to read just the ' ..
        'relevant range. Output includes line numbers in cat -n format.',
    input_schema = {
        type = 'object',
        properties = {
            file_path = { type = 'string', description = 'Absolute or relative path to the file' },
            offset = { type = 'number', description = '1-indexed start line (default 1)' },
            limit = { type = 'number', description = 'Number of lines to read (default 2000; output is capped at ~50KB)' },
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
        limit = (limit and limit >= 1) and math.floor(limit) or DEFAULT_LIMIT
        local last = math.min(total, offset + limit - 1)

        local selected = {}
        for i = offset, last do selected[#selected + 1] = all[i] end
        if #selected == 0 then
            local why = (total == 0) and '(empty file)'
                or string.format('(empty selection: offset %d is past the end)', offset)
            return { content = string.format('%s (%d lines)\n%s', resolved, total, why) }
        end

        local body, shown = add_line_numbers(selected, offset)
        last = offset + shown - 1

        local range = (offset > 1 or last < total)
            and string.format(' (lines %d-%d of %d)', offset, last, total)
            or string.format(' (%d lines)', total)
        local footer = ''
        if last < total then
            footer = string.format('\n\n[Showing lines %d-%d of %d%s. Call Read with offset=%d to continue.]',
                offset, last, total, (shown < #selected) and ', cut at ~50KB' or '', last + 1)
        end
        return { content = resolved .. range .. '\n' .. body .. footer }
    end,
}
