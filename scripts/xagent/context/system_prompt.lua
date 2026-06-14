-- xagent/context/system_prompt.lua — build the system prompt.
-- M1 slice: identity + concise coding instructions + environment. Memory
-- (AGENT.md / CLAUDE.md), skills, agents, etc. are added in later milestones.

local M = {}

local IDENTITY = {
    'You are xagent, a terminal-native local coding assistant running inside the user\'s workspace.',
    'Treat the current working directory as the primary workspace boundary.',
}

local CODING = {
    'Operate directly, be concise, and take concrete actions with tools when useful.',
    'When solving a task: first understand the relevant files, then make focused changes, then verify with the least expensive effective command.',
    'Prefer the Read tool to read files and the Bash tool only when shell execution is actually needed.',
    'When you have finished the task, stop and give a short summary of what you did or found.',
}

local function env_section(opts)
    local lines = {
        'Environment:',
        '- Current working directory: ' .. tostring(opts.cwd or '.'),
        '- Current date: ' .. os.date('%Y-%m-%d'),
        '- Operating system: ' .. (opts.os or (package.config:sub(1, 1) == '\\' and 'Windows' or 'POSIX')),
    }
    return table.concat(lines, '\n')
end

-- opts: { cwd, os?, project_md? }
function M.build(opts)
    opts = opts or {}
    local parts = {}
    for _, s in ipairs(IDENTITY) do parts[#parts + 1] = s end
    for _, s in ipairs(CODING) do parts[#parts + 1] = s end
    parts[#parts + 1] = env_section(opts)
    if opts.project_md and opts.project_md ~= '' then
        parts[#parts + 1] = 'Project memory (from AGENT.md / CLAUDE.md — follow it):\n' .. opts.project_md
    end
    return table.concat(parts, '\n\n')
end

return M
