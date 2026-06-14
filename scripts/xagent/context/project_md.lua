-- xagent/context/project_md.lua — load project memory (AGENT.md / CLAUDE.md).
-- Searches the cwd and a few parent directories for the first match. Returned
-- text is injected into the system prompt.

local fs   = dofile('scripts/core/share/xfs.lua')
local text = dofile('scripts/core/share/xtext.lua')

local M = {}

local NAMES = { 'AGENT.md', 'CLAUDE.md', 'AGENTS.md' }
local MAX_BYTES = 16000
local MAX_LEVELS = 6

-- Returns (content, path) or nil.
function M.load(cwd)
    local dir = cwd or '.'
    for _ = 1, MAX_LEVELS do
        for _, name in ipairs(NAMES) do
            local p = dir .. '/' .. name
            local data = fs.read_file(p)
            if data and #data > 0 then
                data = text.truncate(data, MAX_BYTES, '\n...[project memory truncated]')
                return data, p
            end
        end
        local parent = dir:gsub('[/\\]+$', ''):match('^(.*)[/\\][^/\\]+$')
        if not parent or parent == dir then break end
        dir = parent
    end
    return nil
end

return M
