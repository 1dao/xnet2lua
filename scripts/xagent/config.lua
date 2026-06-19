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
--
-- Profiles ALSO come from ~/.xagent/models.json — models the user adds in the
-- GUI settings page (each { name, base_url, model, auth_style, api_key }). These
-- are tagged source='json' (cfg-defined ones are source='cfg') so the GUI can
-- offer delete only for the user-managed ones. Tokens live in the user's home
-- dir, never in the repo.

local xutils = require('xutils')
local fs     = dofile('scripts/core/share/xfs.lua')

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

-- ── user-managed models (~/.xagent/models.json) ────────────────────────────
function M.models_file()
    return (fs.home():gsub('[/\\]+$', '')) .. '/.xagent/models.json'
end

-- Auto-derive the auth header style from the endpoint. Anthropic and the common
-- /anthropic-compatible gateways (DeepSeek, Volcengine ark, …) all use x-api-key,
-- so that's the default; the user can hand-edit models.json for bearer.
function M.infer_auth_style(_url)
    return 'x-api-key'
end

-- Read the user-added models. Tolerant of either a bare array or { models=[…] }.
function M.load_user_models()
    local data = fs.read_file(M.models_file())
    if not data then return {} end
    local ok, t = pcall(xutils.json_unpack, data)
    if not ok or type(t) ~= 'table' then return {} end
    local arr = (type(t.models) == 'table') and t.models or t
    local out = {}
    if type(arr) == 'table' then
        for _, m in ipairs(arr) do
            if type(m) == 'table' and (m.base_url or m.model) then
                out[#out + 1] = {
                    name       = m.name,
                    base_url   = m.base_url,
                    model      = m.model,
                    auth_style = m.auth_style or M.infer_auth_style(m.base_url),
                    api_key    = m.api_key,
                    verify     = true,
                }
            end
        end
    end
    return out
end

local function save_user_models(list)
    local clean = {}
    for _, m in ipairs(list) do
        clean[#clean + 1] = { name = m.name, base_url = m.base_url,
            model = m.model, auth_style = m.auth_style, api_key = m.api_key }
    end
    fs.mkdirp((fs.home():gsub('[/\\]+$', '')) .. '/.xagent')
    return fs.write_file(M.models_file(), xutils.json_pack({ models = clean }))
end

-- Append a user model. m = { name?, base_url, model, api_key?, auth_style? }.
function M.add_user_model(m)
    local list = M.load_user_models()
    list[#list + 1] = {
        name       = (m.name and m.name ~= '') and m.name or m.model,
        base_url   = m.base_url,
        model      = m.model,
        auth_style = (m.auth_style and m.auth_style ~= '') and m.auth_style
            or M.infer_auth_style(m.base_url),
        api_key    = (m.api_key and m.api_key ~= '') and m.api_key or nil,
    }
    return save_user_models(list)
end

-- Remove the user model at 1-based `index` (its position within models.json).
function M.delete_user_model(index)
    local list = M.load_user_models()
    if not list[index] then return false end
    table.remove(list, index)
    return save_user_models(list)
end

-- Return the full list of configured profiles (always ≥1: the base profile,
-- which defaults to Anthropic when nothing is configured). cfg-defined profiles
-- come first (tagged source='cfg'), then user models from models.json
-- (source='json', with json_index = their slot for delete).
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
    for _, p in ipairs(profiles) do p.source = 'cfg' end

    -- Append user-added models. Their token falls back to the shared one too.
    for i, m in ipairs(M.load_user_models()) do
        m.source = 'json'
        m.json_index = i
        m.api_key = m.api_key or shared_token
        profiles[#profiles + 1] = m
    end

    -- Nothing configured at all → fall back to the base default (Anthropic),
    -- so there is always at least one profile.
    if #profiles == 0 then
        local p = build('', shared_token); p.source = 'cfg'; profiles[1] = p
    end
    return name_profiles(profiles)
end

-- The base profile only (backward-compatible single-config callers).
function M.load()
    return M.load_profiles()[1]
end

return M
