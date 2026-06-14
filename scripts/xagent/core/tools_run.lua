-- xagent/core/tools_run.lua — execute an assistant turn's tool_use blocks.
--
-- M1 slice: serial execution, auto-allow permissions (headless). Builds the
-- tool_result blocks in the SAME order as the tool_use blocks (the API requires
-- strict pairing). Permission/hooks/concurrency land in later milestones.

local registry = require('xagent.tools.registry')
local text = dofile('scripts/core/share/xtext.lua')

local M = {}

-- content_blocks: the assistant message's content array.
-- ctx: tool context ({ cwd, ... }).
-- on_event: optional fn(event) for UI/headless surfacing.
-- Returns an array of tool_result blocks (user-message content).
function M.run(content_blocks, ctx, on_event)
    local function emit(ev) if on_event then on_event(ev) end end
    local results = {}

    for _, block in ipairs(content_blocks) do
        if block.type == 'tool_use' then
            local input = block.input or {}
            emit({ type = 'tool_use', id = block.id, name = block.name, input = input })

            local tool = registry.find(block.name)
            local res
            if not tool then
                res = { content = 'Error: unknown tool "' .. tostring(block.name) .. '"', is_error = true }
            else
                -- M1: auto-allow all tools (headless). Permission engine lands later.
                local ok, r = pcall(tool.call, input, ctx)
                if ok and type(r) == 'table' then
                    res = r
                elseif ok then
                    res = { content = tostring(r), is_error = false }
                else
                    res = { content = 'Error: ' .. tostring(r), is_error = true }
                end
            end

            -- Tool output can contain arbitrary bytes (file contents, command
            -- output). Force valid UTF-8 before it enters the message history,
            -- or the next request's json_pack returns nil → empty body → 400.
            if type(res.content) == 'string' then
                res.content = text.valid_utf8(res.content)
            end

            emit({ type = 'tool_result', id = block.id, name = block.name, result = res })

            -- Conditional skills: a touched file may promote a paths-gated skill
            -- (visible from the next turn). Best-effort — never break a tool turn.
            pcall(function()
                require('xagent.skills').note_tool_use(block.name, input, ctx and ctx.cwd)
            end)

            results[#results + 1] = {
                type = 'tool_result',
                tool_use_id = block.id,
                content = res.content,
                is_error = res.is_error or nil,
            }
        end
    end

    return results
end

return M
