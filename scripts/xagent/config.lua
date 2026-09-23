-- xagent/config.lua — resolve LLM config from cfg files (+ env override).
--
-- Sources, lowest to highest precedence:
--   1. xnet.cfg            (preloaded by the runner; non-secret XAGENT_* keys)
--   2. xagent.local.cfg    (gitignored; the secret XAGENT_AUTH_TOKEN)
--   3. ANTHROPIC_* env     (override, for one-off runs)
--
-- A "profile" is one model/endpoint. The base profile uses the un-suffixed keys
-- (XAGENT_BASE_URL / XAGENT_MODEL / XAGENT_AUTH_STYLE / XAGENT_AUTH_TOKEN /
-- XAGENT_API_FORMAT);
-- additional profiles use a numeric suffix (XAGENT_BASE_URL1, XAGENT_MODEL1, …;
-- then …2, …3). Each numbered profile's token falls back to the shared
-- XAGENT_AUTH_TOKEN when no XAGENT_AUTH_TOKEN{N} is set. M.load_profiles()
-- returns the whole list (the GUI shows one tab per profile); M.load() returns
-- just the base profile (the headless main.lua and tests use this).
--
-- Profiles ALSO come from ~/.xagent/models.json — models the user adds in the
-- GUI settings page (each { name, base_url, model, api_format, auth_style,
-- api_key, proxy }). These
-- are tagged source='json' (cfg-defined ones are source='cfg') so the GUI can
-- offer delete only for the user-managed ones. Editing a cfg-defined profile in
-- the GUI stores an override in the same file instead of rewriting the cfg.
-- Tokens live in the user's home dir, never in the repo.
--
-- Proxy: each profile may carry `proxy` (socks5://, socks5h:// or http://, with
-- optional user:pass@) — XAGENT_PROXY{N} for cfg profiles, the `proxy` field in
-- models.json. A profile without one inherits the shared XAGENT_PROXY; the
-- value 'direct' opts a profile out of that default. Environment variables
-- (HTTPS_PROXY, ALL_PROXY) are deliberately NOT read: the proxy is explicit.

local xutils = require('xutils')
local fs     = dofile('scripts/core/share/xfs.lua')

local M = {}

local MAX_PROFILES = 32

-- Wire protocol of an endpoint: 'anthropic' (Messages) or 'openai' (Chat
-- Completions). Explicit config wins; otherwise guess from the URL, defaulting
-- to anthropic so existing profiles keep working. DeepSeek/Kimi/… serve both
-- (…/anthropic vs. the bare host), so only unambiguous URLs flip to openai.
function M.infer_api_format(url)
    local u = tostring(url or ''):lower()
    if u:find('/anthropic') or u:find('api%.anthropic%.com') then return 'anthropic' end
    if u:find('/chat/completions') or u:find('api%.openai%.com')
        or u:find('openai%.azure%.com') or u:find('/compatible%-mode/') then
        return 'openai'
    end
    return 'anthropic'
end

local function resolve_api_format(explicit, url)
    if explicit and explicit ~= '' then return explicit:lower() end
    return M.infer_api_format(url)
end

local function cfg(key)
    local v = xutils.get_config(key)
    if v ~= nil and v ~= '' then return v end
    return nil
end

local function trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Effective proxy URL for a profile: its own value, else the shared default.
-- 'direct' (or 'none') means no proxy even when a shared default is set.
function M.resolve_proxy(own, shared)
    local v = trim(own)
    if v == '' then v = trim(shared) end
    local lv = v:lower()
    if v == '' or lv == 'direct' or lv == 'none' then return nil end
    return v
end

-- Build one profile from keys with the given numeric suffix ('' = base).
-- shared_token is the base XAGENT_AUTH_TOKEN (+ env), used when a numbered
-- profile has no token of its own. Returns the cfg table, or nil when a numbered
-- slot is entirely empty (no base_url AND no model → stop scanning).
-- The proxy is left raw in proxy_own; load_profiles resolves it against the
-- shared XAGENT_PROXY after any GUI override has been applied.
local function build(suffix, shared_token)
    local base_url = cfg('XAGENT_BASE_URL' .. suffix)
    local model    = cfg('XAGENT_MODEL' .. suffix)
    if suffix ~= '' and not base_url and not model then return nil end

    local token = cfg('XAGENT_AUTH_TOKEN' .. suffix) or shared_token
    local explicit_format = cfg('XAGENT_API_FORMAT' .. suffix)
    if explicit_format == 'openai' then
        base_url = base_url or 'https://api.openai.com/v1'
        model    = model or 'gpt-4.1'
    elseif suffix == '' then
        base_url = base_url or os.getenv('ANTHROPIC_BASE_URL') or 'https://api.anthropic.com'
        model    = model or os.getenv('ANTHROPIC_MODEL') or 'claude-sonnet-4-5'
    else
        base_url = base_url or 'https://api.anthropic.com'
        model    = model or 'claude-sonnet-4-5'
    end
    local api_format = resolve_api_format(explicit_format, base_url)

    return {
        key        = 'cfg' .. suffix,              -- stable id: 'cfg', 'cfg1', …
        api_key    = token,
        base_url   = base_url,
        model      = model,
        api_format = api_format,
        auth_style = cfg('XAGENT_AUTH_STYLE' .. suffix) or M.infer_auth_style(base_url, api_format),
        max_tokens_param = cfg('XAGENT_MAX_TOKENS_PARAM' .. suffix),
        name       = cfg('XAGENT_NAME' .. suffix),   -- explicit label (nil → derived below)
        proxy_own  = cfg('XAGENT_PROXY' .. suffix),
        verify     = true,
    }
end

local function host_of(url)
    return (tostring(url or ''):gsub('^https?://', '')):match('^([^/]+)') or ''
end

-- Assign each profile a unique display name: explicit XAGENT_NAME{N} wins, else
-- the model id; collisions (same model twice) get the host appended, then a
-- counter, so tab labels stay distinguishable. The explicit name (or nil) is
-- kept as name_own so the edit form can tell a derived label from a chosen one.
local function name_profiles(profiles)
    local seen = {}
    for _, p in ipairs(profiles) do
        p.name_own = p.name
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
-- { models = [ {id, name, base_url, model, api_format, auth_style, api_key,
--               proxy, max_tokens_param}, … ],
--   overrides = { cfg1 = {model?, proxy?, …}, … } }
-- `overrides` holds GUI edits to cfg-file profiles, keyed by profile key, so
-- the repo's cfg files are never rewritten.
function M.models_file()
    return (fs.home():gsub('[/\\]+$', '')) .. '/.xagent/models.json'
end

-- Auto-derive the auth header style from the endpoint. Anthropic and the common
-- /anthropic-compatible gateways (DeepSeek, Volcengine ark, …) all use x-api-key;
-- OpenAI-format endpoints use a Bearer token, except Azure's `api-key` header.
-- The user can hand-edit models.json to override.
function M.infer_auth_style(url, api_format)
    if (api_format or M.infer_api_format(url)) == 'openai' then
        if tostring(url or ''):lower():find('openai%.azure%.com') then return 'api-key' end
        return 'bearer'
    end
    return 'x-api-key'
end

-- The fields a GUI edit may change (on a user model or as a cfg override).
local EDITABLE = { 'name', 'base_url', 'model', 'api_format', 'api_key', 'proxy' }

-- Read models.json. Tolerant of a bare array (the oldest format).
local function read_store()
    local data = fs.read_file(M.models_file())
    local store = { models = {}, overrides = {} }
    if not data then return store end
    local ok, t = pcall(xutils.json_unpack, data)
    if not ok or type(t) ~= 'table' then return store end
    local arr = (type(t.models) == 'table') and t.models or t
    for _, m in ipairs(arr) do
        if type(m) == 'table' and (m.base_url or m.model) then
            -- Entries saved before ids existed get one from their position as
            -- read, so their key stays the same once it is written back.
            if m.id == nil then m.id = '#' .. (#store.models + 1) end
            store.models[#store.models + 1] = m
        end
    end
    if type(t.overrides) == 'table' then
        for k, v in pairs(t.overrides) do
            if type(k) == 'string' and type(v) == 'table' then store.overrides[k] = v end
        end
    end
    return store
end

local id_seq = 0
local function new_id()
    id_seq = id_seq + 1
    return string.format('m%x%x', os.time(), id_seq)
end

local function write_store(store)
    local clean = {}
    for _, m in ipairs(store.models) do
        clean[#clean + 1] = { id = m.id or new_id(), name = m.name, base_url = m.base_url,
            model = m.model, api_format = m.api_format, auth_style = m.auth_style,
            max_tokens_param = m.max_tokens_param, api_key = m.api_key, proxy = m.proxy }
    end
    local out = { models = clean }
    if next(store.overrides) then out.overrides = store.overrides end
    local path = M.models_file()
    fs.mkdirp(path:match('^(.*)[/\\][^/\\]*$') or '.')
    return fs.write_file(path, xutils.json_pack(out))
end

-- The user-added models as profiles (proxy still raw in proxy_own).
function M.load_user_models()
    local out = {}
    for _, m in ipairs(read_store().models) do
        local api_format = resolve_api_format(m.api_format, m.base_url)
        out[#out + 1] = {
            key        = 'json:' .. tostring(m.id),
            name       = m.name,
            base_url   = m.base_url,
            model      = m.model,
            api_format = api_format,
            max_tokens_param = m.max_tokens_param,
            auth_style = m.auth_style or M.infer_auth_style(m.base_url, api_format),
            api_key    = m.api_key,
            proxy_own  = m.proxy,
            verify     = true,
        }
    end
    return out
end

local function nonblank(s)
    s = trim(s)
    return s ~= '' and s or nil
end

-- Append a user model. m = { name?, base_url, model, api_key?, api_format?,
-- auth_style?, proxy? }.
function M.add_user_model(m)
    local store = read_store()
    local api_format = resolve_api_format(m.api_format, m.base_url)
    store.models[#store.models + 1] = {
        id         = new_id(),
        name       = nonblank(m.name) or m.model,
        base_url   = m.base_url,
        model      = m.model,
        api_format = api_format,
        auth_style = nonblank(m.auth_style) or M.infer_auth_style(m.base_url, api_format),
        api_key    = nonblank(m.api_key),
        proxy      = nonblank(m.proxy),
    }
    return write_store(store)
end

-- Remove the user model at 1-based `index` (its position within models.json).
function M.delete_user_model(index)
    local store = read_store()
    if not store.models[index] then return false end
    table.remove(store.models, index)
    return write_store(store)
end

-- Apply edited fields `e` (subset of EDITABLE; nil = unchanged, api_key ''
-- = unchanged, proxy '' = inherit the default) to the user model at `index`.
-- The auth header style is re-derived only when the endpoint or protocol moved.
function M.update_user_model(index, e)
    local store = read_store()
    local m = store.models[index]
    if not m then return false end
    local old_url, old_fmt = m.base_url, resolve_api_format(m.api_format, m.base_url)
    if nonblank(e.name) then m.name = trim(e.name) end
    if nonblank(e.base_url) then m.base_url = trim(e.base_url) end
    if nonblank(e.model) then m.model = trim(e.model) end
    if nonblank(e.api_key) then m.api_key = trim(e.api_key) end
    if e.proxy ~= nil then m.proxy = nonblank(e.proxy) end
    -- An explicit protocol wins; a moved endpoint re-infers it; otherwise keep.
    if nonblank(e.api_format) then
        m.api_format = trim(e.api_format):lower()
    elseif m.base_url ~= old_url then
        m.api_format = M.infer_api_format(m.base_url)
    else
        m.api_format = old_fmt
    end
    if m.base_url ~= old_url or m.api_format ~= old_fmt then
        m.auth_style = M.infer_auth_style(m.base_url, m.api_format)
    end
    return write_store(store)
end

-- Record GUI edits to the cfg-file profile `key` ('cfg', 'cfg1', …). Fields in
-- `e` are merged into any existing override; api_key '' leaves it unchanged.
function M.set_cfg_override(key, e)
    local store = read_store()
    local ov = store.overrides[key] or {}
    for _, f in ipairs(EDITABLE) do
        local v = e[f]
        if f == 'proxy' then
            if v ~= nil then ov.proxy = trim(v) end     -- '' = inherit, kept
        elseif nonblank(v) then
            ov[f] = trim(v)
        end
    end
    store.overrides[key] = ov
    return write_store(store)
end

-- Drop every GUI edit of the cfg-file profile `key`.
function M.clear_cfg_override(key)
    local store = read_store()
    if not store.overrides[key] then return false end
    store.overrides[key] = nil
    return write_store(store)
end

local function apply_override(p, ov)
    local old_url, old_fmt = p.base_url, p.api_format
    for _, f in ipairs({ 'name', 'base_url', 'model', 'api_key' }) do
        if nonblank(ov[f]) then p[f] = ov[f] end
    end
    if ov.proxy ~= nil then p.proxy_own = ov.proxy end
    if nonblank(ov.api_format) or p.base_url ~= old_url then
        p.api_format = resolve_api_format(ov.api_format, p.base_url)
    end
    if p.base_url ~= old_url or p.api_format ~= old_fmt then
        p.auth_style = M.infer_auth_style(p.base_url, p.api_format)
    end
    p.overridden = true
end

-- Return the full list of configured profiles (always ≥1: the base profile,
-- which defaults to Anthropic when nothing is configured). cfg-defined profiles
-- come first (tagged source='cfg', with any GUI override applied), then user
-- models from models.json (source='json', with json_index = their slot).
-- Every profile has a stable `key` so open tabs can follow edits.
function M.load_profiles()
    -- Best-effort: pull in the gitignored secrets file if present. Values
    -- already loaded (xnet.cfg, argv) keep priority, so this only adds keys.
    pcall(function() xutils.load_config('xagent.local.cfg') end)

    local shared_token = cfg('XAGENT_AUTH_TOKEN')
        or os.getenv('ANTHROPIC_AUTH_TOKEN')
        or os.getenv('ANTHROPIC_API_KEY')
    local shared_proxy = cfg('XAGENT_PROXY')

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
    local user_models = M.load_user_models()
    -- Nothing configured at all → fall back to the base default (Anthropic),
    -- so there is always at least one profile.
    if #profiles == 0 and #user_models == 0 then profiles[1] = build('', shared_token) end

    local overrides = read_store().overrides
    for _, p in ipairs(profiles) do
        p.source = 'cfg'
        if overrides[p.key] then apply_override(p, overrides[p.key]) end
    end

    -- Append user-added models. Their token falls back to the shared one too.
    for i, m in ipairs(user_models) do
        m.source = 'json'
        m.json_index = i
        m.api_key = m.api_key or shared_token
        profiles[#profiles + 1] = m
    end

    for _, p in ipairs(profiles) do
        p.proxy = M.resolve_proxy(p.proxy_own, shared_proxy)
    end
    return name_profiles(profiles)
end

-- The base profile only (backward-compatible single-config callers).
function M.load()
    return M.load_profiles()[1]
end

return M
