-- xagent/config.lua — resolve LLM config from cfg files (+ env override).
--
-- Sources, lowest to highest precedence:
--   1. xnet.cfg            (preloaded by the runner; non-secret XAGENT_* keys)
--   2. xagent.local.cfg    (gitignored; the secret XAGENT_AUTH_TOKEN)
--   3. ANTHROPIC_* env     (override, for one-off runs)
-- Keys: XAGENT_BASE_URL, XAGENT_MODEL, XAGENT_AUTH_STYLE, XAGENT_AUTH_TOKEN.

local xutils = require('xutils')

local M = {}

local function cfg(key)
    local v = xutils.get_config(key)
    if v ~= nil and v ~= '' then return v end
    return nil
end

function M.load()
    -- Best-effort: pull in the gitignored secrets file if present. Values
    -- already loaded (xnet.cfg, argv) keep priority, so this only adds keys.
    pcall(function() xutils.load_config('xagent.local.cfg') end)

    local token = cfg('XAGENT_AUTH_TOKEN')
        or os.getenv('ANTHROPIC_AUTH_TOKEN')
        or os.getenv('ANTHROPIC_API_KEY')

    return {
        api_key = token,
        base_url = cfg('XAGENT_BASE_URL') or os.getenv('ANTHROPIC_BASE_URL')
            or 'https://api.anthropic.com',
        model = cfg('XAGENT_MODEL') or os.getenv('ANTHROPIC_MODEL')
            or 'claude-sonnet-4-5',
        auth_style = cfg('XAGENT_AUTH_STYLE') or 'x-api-key',
        verify = true,
    }
end

return M
