-- xagent/mcp/config.lua — load + validate `mcpServers` declarations.
--
-- Two scopes, project overriding user on a name clash (same precedence model as
-- the rest of xagent's config):
--   user:    ~/.xagent/mcp.json
--   project: <cwd>/.mcp.json          (the de-facto Claude Code project file)
-- Both use the standard shape:  { "mcpServers": { "<name>": { ...config } } }.
--
-- Each server is one of three transport types (validated here, connected by
-- client.lua):
--   stdio:  { "command": "...", "args": [...], "env": { ... } }   (type optional)
--   http:   { "type": "http", "url": "https://...", "headers": { ... } }
--   sse:    { "type": "sse",  "url": "https://...", "headers": { ... } }
--
-- Loading is best-effort: a malformed entry is dropped with an error string, it
-- never throws (one bad server must not take the whole agent down).
--
-- Reference: ../easy-agent/src/services/mcp/config.ts.

local fs = dofile('scripts/core/share/xfs.lua')
local xutils = require('xutils')

local M = {}

-- Validate a single raw server table. Returns (config, nil) or (nil, err).
-- The returned config always carries an explicit `type`.
function M.validate(name, raw)
    if type(raw) ~= 'table' then
        return nil, 'mcpServers.' .. name .. ' must be an object'
    end
    local t = raw.type
    if t == nil then
        -- Infer: a `url` means a remote server, otherwise stdio (the common
        -- ecosystem shape omits `type` for stdio).
        t = (type(raw.url) == 'string') and 'http' or 'stdio'
    end
    if t ~= 'stdio' and t ~= 'http' and t ~= 'sse' then
        return nil, 'mcpServers.' .. name .. ": unsupported transport '" ..
            tostring(t) .. "' (use stdio|http|sse)"
    end

    if t == 'http' or t == 'sse' then
        if type(raw.url) ~= 'string' or raw.url == '' then
            return nil, 'mcpServers.' .. name .. ": '" .. t .. "' transport requires a 'url' string"
        end
        local headers
        if raw.headers ~= nil then
            if type(raw.headers) ~= 'table' then
                return nil, 'mcpServers.' .. name .. ": 'headers' must be an object"
            end
            headers = {}
            for k, v in pairs(raw.headers) do
                if type(v) ~= 'string' then
                    return nil, 'mcpServers.' .. name .. ': headers.' .. tostring(k) .. ' must be a string'
                end
                headers[k] = v
            end
        end
        return { type = t, url = raw.url, headers = headers }
    end

    -- stdio
    if type(raw.command) ~= 'string' or raw.command == '' then
        return nil, 'mcpServers.' .. name .. ": 'command' is required for the stdio transport"
    end
    local args = {}
    if raw.args ~= nil then
        if type(raw.args) ~= 'table' then
            return nil, 'mcpServers.' .. name .. ": 'args' must be an array of strings"
        end
        for i, a in ipairs(raw.args) do
            if type(a) ~= 'string' then
                return nil, 'mcpServers.' .. name .. ": 'args' must contain only strings"
            end
            args[i] = a
        end
    end
    local env
    if raw.env ~= nil then
        if type(raw.env) ~= 'table' then
            return nil, 'mcpServers.' .. name .. ": 'env' must be a string->string map"
        end
        env = {}
        for k, v in pairs(raw.env) do
            if type(v) ~= 'string' then
                return nil, 'mcpServers.' .. name .. ': env.' .. tostring(k) .. ' must be a string'
            end
            env[k] = v
        end
    end
    return { type = 'stdio', command = raw.command, args = args, env = env }
end

-- Extract { name -> config } from a decoded settings blob, appending any
-- per-server errors to `errors`. `scope` is stamped onto each config.
function M.extract(raw, scope, errors)
    local out = {}
    if type(raw) ~= 'table' or raw.mcpServers == nil then return out end
    if type(raw.mcpServers) ~= 'table' then
        errors[#errors + 1] = tostring(scope) .. ": 'mcpServers' must be an object"
        return out
    end
    for name, rc in pairs(raw.mcpServers) do
        local cfg, err = M.validate(name, rc)
        if cfg then
            cfg.scope = scope
            out[name] = cfg
        else
            errors[#errors + 1] = err
        end
    end
    return out
end

local function read_json(path)
    local data = fs.read_file(path)
    if not data then return nil end                  -- absent file: not an error
    data = data:gsub('^\239\187\191', '')            -- strip UTF-8 BOM
    local ok, t = pcall(xutils.json_unpack, data)
    if not ok or type(t) ~= 'table' then
        return nil, 'invalid JSON in ' .. path
    end
    return t
end

-- Load all configured servers for `cwd`. Returns (servers, errors) where
-- servers = { name -> config } (project entries override user entries).
function M.load(cwd)
    local errors = {}
    local servers = {}

    local home = (fs.home():gsub('[/\\]+$', ''))
    local ut, uerr = read_json(home .. '/.xagent/mcp.json')
    if uerr then errors[#errors + 1] = uerr end
    if ut then
        for k, v in pairs(M.extract(ut, 'user', errors)) do servers[k] = v end
    end

    if cwd and cwd ~= '' then
        local pt, perr = read_json((cwd:gsub('[/\\]+$', '')) .. '/.mcp.json')
        if perr then errors[#errors + 1] = perr end
        if pt then
            for k, v in pairs(M.extract(pt, 'project', errors)) do servers[k] = v end
        end
    end

    return servers, errors
end

return M
