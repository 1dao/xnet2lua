-- xsse.lua — incremental Server-Sent Events parser.
--
-- Pure text -> events; no I/O, no transport knowledge. Feed decoded SSE body
-- bytes (already de-chunked) and get back complete events. Partial lines and
-- partial events are buffered across feeds, so callers can push arbitrary byte
-- splits straight off the socket. Dependency-free; any thread can `dofile` it.
--
-- Event shape: { event = <string|nil>, data = <string> }
--   - `event` is the last `event:` field value, or nil if none was sent.
--   - `data`  is all `data:` lines for the event joined with "\n" (SSE spec).
--
-- Usage:
--   local sse = dofile('scripts/core/share/xsse.lua')
--   local p = sse.new()
--   for _, ev in ipairs(p:feed(bytes)) do handle(ev.event, ev.data) end

local M = {}
M.__index = M

function M.new()
    return setmetatable({
        buf = '',
        cur_event = nil,
        cur_data = {},
        have = false,        -- whether the current event has any field set
    }, M)
end

-- Feed a chunk of decoded SSE text. Returns an array of complete events.
function M:feed(text)
    if text == nil or text == '' then return {} end
    self.buf = self.buf .. text
    local out = {}

    while true do
        local nl = self.buf:find('\n', 1, true)
        if not nl then break end

        local line = self.buf:sub(1, nl - 1)
        self.buf = self.buf:sub(nl + 1)
        if line:sub(-1) == '\r' then line = line:sub(1, -2) end   -- strip CR

        if line == '' then
            -- Blank line ends the event; dispatch it if anything accumulated.
            if self.have then
                out[#out + 1] = {
                    event = self.cur_event,
                    data = table.concat(self.cur_data, '\n'),
                }
            end
            self.cur_event = nil
            self.cur_data = {}
            self.have = false
        elseif line:sub(1, 1) == ':' then
            -- comment line — ignore
        else
            local field, value = line:match('^([^:]*):[ ]?(.*)$')
            if not field then field, value = line, '' end
            if field == 'event' then
                self.cur_event = value
                self.have = true
            elseif field == 'data' then
                self.cur_data[#self.cur_data + 1] = value
                self.have = true
            end
            -- `id:` / `retry:` and unknown fields are ignored
        end
    end

    return out
end

return M
