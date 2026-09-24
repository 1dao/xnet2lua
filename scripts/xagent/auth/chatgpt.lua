-- Shared ChatGPT account lifecycle. Hosts can replace credential storage.
local oauth = dofile('scripts/core/share/xoauth.lua')
local json = require('xutils')
local async = dofile('scripts/core/share/xasync.lua')
local http = dofile('scripts/core/share/xhttp_client.lua')
local M = { endpoint = 'https://chatgpt.com/backend-api/codex/responses' }
local storage, account, pending, refreshing
local waiters = {}
local generation = 0

function M.set_storage(value) storage = value; account = nil end
local function store()
    if not storage then storage = require('xagent.auth.file_store') end
    return storage
end
function M.account()
    if not account then account = store().load() end
    return account
end
local function save(value)
    local ok, err = store().save(value)
    assert(ok, err or 'Cannot save ChatGPT credentials')
    account = value
end
function M.logout()
    assert(not refreshing, 'ChatGPT refresh in progress')
    M.cancel()
    save(nil)
end
function M.provider(proxy)
    return { auth_url = 'https://auth.openai.com/oauth/authorize', token_url = 'https://auth.openai.com/oauth/token',
        client_id = 'app_EMoamEEZ73f0CkXaXp7hrann', client_auth = 'none', token_encoding = 'form',
        scope = 'openid profile email offline_access', proxy = proxy, token_timeout_ms = 30000,
        authorize_params = { id_token_add_organizations = 'true', codex_cli_simplified_flow = 'true', originator = 'codua' } }
end
local function http_call(opts)
    return async.await(function(resolve) http.request(opts, resolve) end)
end
local function claims(token)
    if type(token) ~= 'string' then return {} end
    local encoded = token:match('^[^.]+%.([^.]+)%.')
    if not encoded then return {} end
    local ok, value = pcall(function() return json.json_unpack(oauth.b64url_decode(encoded)) end)
    return ok and type(value) == 'table' and value or {}
end
function M.credentials(tokens, previous, now)
    assert(type(tokens.access_token) == 'string' and tokens.access_token ~= '', 'Missing access token')
    previous = previous or {}
    local id, access = claims(tokens.id_token), claims(tokens.access_token)
    local function account_id(c)
        return c.chatgpt_account_id or (c['https://api.openai.com/auth'] or {}).chatgpt_account_id
            or (c.organizations and c.organizations[1] and c.organizations[1].id)
    end
    local result = { access_token = tokens.access_token,
        refresh_token = tokens.refresh_token or previous.refresh_token,
        account_id = account_id(id) or account_id(access) or previous.account_id,
        email = id.email or access.email or previous.email,
        expires_at = (now or os.time()) + (tonumber(tokens.expires_in) or 3600) }
    assert(type(result.refresh_token) == 'string' and result.refresh_token ~= '', 'Missing refresh token')
    return result
end
function M.begin(proxy, now)
    assert(not pending, 'A ChatGPT login is already running')
    assert(not refreshing, 'ChatGPT refresh in progress')
    local verifier, challenge, err = oauth.pkce_pair()
    assert(verifier, err)
    local state = assert(oauth.random_urlsafe(43))
    pending = { verifier = verifier, state = state, expires = (now or os.time()) + 300,
        provider = M.provider(proxy), redirect_uri = 'http://localhost:1455/auth/callback' }
    return assert(oauth.build_authorize_url(pending.provider, { redirect_uri = pending.redirect_uri,
        state = state, code_challenge = challenge }))
end
function M.cancel() pending = nil; generation = generation + 1 end
function M.finish(query, transport, now)
    local p = pending
    local login_generation = generation
    assert(p, 'No ChatGPT login pending')
    assert((now or os.time()) < p.expires, 'ChatGPT login expired')
    assert(type(query.state) == 'string' and query.state == p.state, 'Invalid OAuth state')
    pending = nil -- one-time callback, including errors
    assert(not query.error, 'ChatGPT authorization rejected: ' .. tostring(query.error))
    assert(type(query.code) == 'string' and query.code ~= '', 'Missing authorization code')
    local tokens, err = oauth.exchange_code(p.provider, { code = query.code, redirect_uri = p.redirect_uri,
        code_verifier = p.verifier }, transport or http_call)
    assert(tokens, err and err.message or 'Token exchange failed')
    assert(generation == login_generation, 'ChatGPT login cancelled')
    local value = M.credentials(tokens)
    save(value)
    return value
end

-- All tabs in this process share one refresh and the rotated credential.
function M.ensure(proxy, transport, now)
    local value = M.account()
    assert(value, '请先登录 ChatGPT')
    if value.access_token and (tonumber(value.expires_at) or 0) > (now or os.time()) + 60 then return value end
    if refreshing then
        local result, err = async.await(function(resolve) waiters[#waiters + 1] = resolve end)
        assert(result, err); return result
    end
    refreshing = true
    local ok, result = pcall(function()
        local tokens, err = oauth.refresh_token(M.provider(proxy), { refresh_token = value.refresh_token }, transport or http_call)
        assert(tokens, err and ('ChatGPT 刷新失败，请重新登录：' .. tostring(err.oauth_error or err.message)) or 'Token refresh failed')
        local updated = M.credentials(tokens, value, now)
        save(updated)
        return updated
    end)
    refreshing = false
    local listeners = waiters; waiters = {}
    for _, resolve in ipairs(listeners) do resolve(ok and result or nil, not ok and result or nil) end
    assert(ok, result)
    return result
end
return M
