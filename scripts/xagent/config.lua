-- xagent/config.lua — resolve LLM config from cfg files (+ env override).
--
-- Sources, lowest to highest precedence:
--   1. xnet.cfg            (preloaded by the runner; non-secret XAGENT_* keys)
--   2. xagent.local.cfg    (gitignored; the secret XAGENT_AUTH_TOKEN)
--   3. ANTHROPIC_* env     (override, for one-off runs)
--
-- A "profile" is one model/endpoint. The base profile uses the un-suffixed keys
-- (XAGENT_BASE_URL / XAGENT_MODEL / XAGENT_AUTH_STYLE / XAGENT_AUTH_TOKEN);
-- additional profiles use a numeric suffix (XAGENT_BASE_URL1, XAGENT_MODEL1, …;
-- then …2, …3). Each numbered profile's token falls back to the shared
-- XAGENT_AUTH_TOKEN when no XAGENT_AUTH_TOKEN{N} is set. M.load_profiles()
-- returns the whole list (the GUI shows one tab per profile); M.load() returns
-- just the base profile (the headless main.lua and tests use this).

local xutils = require('xutils')

local M = {}

local MAX_PROFILES = 32

local function cfg(key)
    local v = xutils.get_config(key)
    if v ~= nil and v ~= '' then return v end
    return nil
end

-- Build one profile from keys with the given numeric suffix ('' = base).
-- shared_token is the base XAGENT_AUTH_TOKEN (+ env), used when a numbered
-- profile has no token of its own. Returns the cfg table, or nil when a numbered
-- slot is entirely empty (no base_url AND no model → stop scanning).
local function build(suffix, shared_token)
    local base_url = cfg('XAGENT_BASE_URL' .. suffix)
    local model    = cfg('XAGENT_MODEL' .. suffix)
    if suffix ~= '' and not base_url and not model then return nil end

    local token = cfg('XAGENT_AUTH_TOKEN' .. suffix) or shared_token
    if suffix == '' then
        base_url = base_url or os.getenv('ANTHROPIC_BASE_URL') or 'https://api.anthropic.com'
        model    = model or os.getenv('ANTHROPIC_MODEL') or 'claude-sonnet-4-5'
    else
        base_url = base_url or 'https://api.anthropic.com'
        model    = model or 'claude-sonnet-4-5'
    end

    return {
        api_key    = token,
        base_url   = base_url,
        model      = model,
        auth_style = cfg('XAGENT_AUTH_STYLE' .. suffix) or 'x-api-key',
        name       = cfg('XAGENT_NAME' .. suffix),   -- explicit label (nil → derived below)
        verify     = true,
    }
end

local function host_of(url)
    return (tostring(url or ''):gsub('^https?://', '')):match('^([^/]+)') or ''
end

-- Assign each profile a unique display name: explicit XAGENT_NAME{N} wins, else
-- the model id; collisions (same model twice) get the host appended, then a
-- counter, so tab labels stay distinguishable.
local function name_profiles(profiles)
    local seen = {}
    for _, p in ipairs(profiles) do
        local label = p.name or p.model or '?'
        if seen[label] then
            local host = host_of(p.base_url)
            if host ~= '' then label = label .. ' @ ' .. host end
        end
        local final, k = label, 2
        while seen[final] do final = label .. ' (' .. k .. ')'; k = k + 1 end
        seen[final] = true
        p.name = final
    end
    return profiles
end

-- Return the full list of configured profiles (always ≥1: the base profile,
-- which defaults to Anthropic when nothing is configured).
function M.load_profiles()
    -- Best-effort: pull in the gitignored secrets file if present. Values
    -- already loaded (xnet.cfg, argv) keep priority, so this only adds keys.
    pcall(function() xutils.load_config('xagent.local.cfg') end)

    local shared_token = cfg('XAGENT_AUTH_TOKEN')
        or os.getenv('ANTHROPIC_AUTH_TOKEN')
        or os.getenv('ANTHROPIC_API_KEY')

    local profiles = {}
    -- The base (un-suffixed) profile is the primary tab — but include it ONLY
    -- when it's actually configured. If the user defines only numbered profiles
    -- (the un-suffixed keys are absent/commented), don't inject a phantom
    -- Anthropic-default tab alongside them.
    if cfg('XAGENT_BASE_URL') or cfg('XAGENT_MODEL') then
        profiles[#profiles + 1] = build('', shared_token)
    end
    for n = 1, MAX_PROFILES do
        local p = build(tostring(n), shared_token)
        if not p then break end                         -- first empty slot stops the scan
        profiles[#profiles + 1] = p
    end
    -- Nothing configured at all → fall back to the base default (Anthropic),
    -- so there is always at least one profile.
    if #profiles == 0 then profiles[1] = build('', shared_token) end
    return name_profiles(profiles)
end

-- The base profile only (backward-compatible single-config callers).
function M.load()
    return M.load_profiles()[1]
end

return M
