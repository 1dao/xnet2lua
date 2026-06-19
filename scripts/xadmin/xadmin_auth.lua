-- xadmin_auth.lua - shared auth primitives for the xadmin console.
--
-- Loaded (dofile'd) by both the HTTP workers and the MAIN thread. Holds NO
-- module-level mutable state, so it is safe to load on any thread. State that
-- needs to persist (e.g. the JWT signing secret) is kept in the xadmin.json
-- config file (different from xadmin_db.json) so it survives restarts but is
-- decoupled from the MySQL lifecycle.
--
-- Responsibilities:
--   * base64url encode/decode (used by JWT + PKCE)
--   * JWT HS256 sign/verify (claims: iss, aud, exp, iat, nbf, sub, ...)
--   * PKCE S256 pair generator (code_verifier, code_challenge)
--   * self-contained signed OAuth2 state (HMAC over JSON, no server-side store)
--   * load / persist server-side secrets (jwt_hs256_secret, oauth_state_secret)
--   * load OAuth2 provider config (XADMIN_OAUTH_<NAME>_*)
--   * OIDC discovery via /.well-known/openid-configuration
--
-- Note on RS256: this module does NOT verify RS256 JWTs. The codebase does
-- not ship a bigint-based RSA verifier, and adding one is out of scope for
-- the "minimal" target. IdPs that sign with RS256 (the common case) are still
-- supported for OAuth2 login, but the id_token is treated as informational;
-- the user identity is read from the /userinfo endpoint (authenticated by
-- access_token). For strict verification, point the IdP at HS256 or front
-- xadmin with an API gateway that does RS256 verification and forwards
-- HS256-signed assertions to /api/auth/jwt.

local xutils = require('xutils')   -- C-backed sha256 / hmac_sha256 / hex / base64
local oauth  = dofile('scripts/core/share/xoauth.lua')

local M = {}

local sbyte = string.byte

-- Constant-time-ish comparison for equal-length strings (HMAC/signature check).
local function ct_equal(a, b)
    a, b = tostring(a or ''), tostring(b or '')
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = diff | (sbyte(a, i) ~ sbyte(b, i))
    end
    return diff == 0
end

-- Shared OAuth primitives. Keep these names as the xadmin compatibility API.
M.random_bytes  = oauth.random_bytes
M.random_urlsafe = oauth.random_urlsafe
M.b64url_encode = oauth.b64url_encode
M.b64url_decode = oauth.b64url_decode

function M.random_hex(n)
    local raw, err = oauth.random_bytes(n or 16)
    if not raw then return nil, err end
    return xutils.hex_encode(raw)
end

-- ---------------------------------------------------------------------------
-- JWT HS256 (RFC 7519 + RFC 7515 §3.2)
-- ---------------------------------------------------------------------------
local function json_or_nil(v) return xutils.json_pack(v) end

function M.jwt_sign_hs256(secret, claims, header_extra)
    local header = { alg = 'HS256', typ = 'JWT' }
    if type(header_extra) == 'table' then
        for k, v in pairs(header_extra) do header[k] = v end
    end
    local h = json_or_nil(header)
    local p = json_or_nil(claims or {})
    if not h or not p then return nil, 'json pack failed' end
    local h64 = M.b64url_encode(h)
    local p64 = M.b64url_encode(p)
    local signing_input = h64 .. '.' .. p64
    -- RFC 7515 §3.2: the JWS signature is base64url(raw HMAC), NOT hex. Hex
    -- here would be non-interoperable with every standard JWT library (both
    -- directions), which is the whole point of the "gateway forwards an
    -- HS256 assertion" use case.
    local sig = M.b64url_encode(xutils.hmac_sha256(secret, signing_input))
    return signing_input .. '.' .. sig
end

-- Verify a JWT and return the claims table on success, or nil + reason.
--   opts: { iss=string|table, aud=string|table, leeway=seconds (default 30),
--           verify_exp=bool (default true), verify_nbf=bool (default true) }
function M.jwt_verify_hs256(secret, token, opts)
    token = tostring(token or '')
    if secret == nil or secret == '' then return nil, 'no secret' end
    if token == '' then return nil, 'empty token' end
    local parts = {}
    for p in token:gmatch('[^.]+') do parts[#parts + 1] = p end
    if #parts ~= 3 then return nil, 'malformed' end
    local signing_input = parts[1] .. '.' .. parts[2]
    local expected = M.b64url_encode(xutils.hmac_sha256(secret, signing_input))
    if not ct_equal(parts[3], expected) then return nil, 'bad signature' end

    local header_bytes = M.b64url_decode(parts[1])
    local payload_bytes = M.b64url_decode(parts[2])
    local header = xutils.json_unpack(header_bytes)
    local claims = xutils.json_unpack(payload_bytes)
    if type(header) ~= 'table' or type(claims) ~= 'table' then
        return nil, 'bad json'
    end
    if header.alg ~= 'HS256' then
        return nil, 'unsupported alg: ' .. tostring(header.alg)
    end

    opts = opts or {}
    local leeway = tonumber(opts.leeway) or 0
    local now = os.time()

    if opts.iss ~= nil then
        local ok = (type(opts.iss) == 'table' and opts.iss[claims.iss])
            or (type(opts.iss) == 'string' and claims.iss == opts.iss)
        if not ok then return nil, 'bad iss' end
    end
    if opts.aud ~= nil then
        local aud = claims.aud
        local ok
        if type(aud) == 'string' then
            ok = (type(opts.aud) == 'table' and opts.aud[aud])
             or (type(opts.aud) == 'string' and aud == opts.aud)
        elseif type(aud) == 'table' then
            ok = false
            for _, a in ipairs(aud) do
                if (type(opts.aud) == 'table' and opts.aud[a])
                or (type(opts.aud) == 'string' and a == opts.aud) then
                    ok = true; break
                end
            end
        end
        if not ok then return nil, 'bad aud' end
    end
    if (opts.verify_exp ~= false) and tonumber(claims.exp) then
        if now > tonumber(claims.exp) + leeway then return nil, 'expired' end
    end
    if (opts.verify_nbf ~= false) and tonumber(claims.nbf) then
        if now + leeway < tonumber(claims.nbf) then return nil, 'nbf' end
    end
    return claims
end

-- PKCE and signed state are provider-independent and now live in xoauth.
M.pkce_pair   = oauth.pkce_pair
M.sign_state  = oauth.sign_state
M.verify_state = oauth.verify_state

-- ---------------------------------------------------------------------------
-- Server-side config (xadmin.json) -- secrets only, never DB credentials
-- ---------------------------------------------------------------------------
function M.config_path()
    return xutils.get_config('XADMIN_CONFIG', 'xadmin.json')
end

function M.load_server_config()
    local path = M.config_path()
    local f = io.open(path, 'rb')
    if not f then return {} end
    local raw = f:read('*a')
    f:close()
    if not raw or raw == '' then return {} end
    local obj = xutils.json_unpack(raw)
    return type(obj) == 'table' and obj or {}
end

function M.save_server_config(tbl)
    local path = M.config_path()
    local data, err = xutils.json_pack(tbl or {})
    if not data then return false, 'json pack failed: ' .. tostring(err) end
    local tmp = path .. '.tmp'
    local f, ferr = io.open(tmp, 'wb')
    if not f then return false, 'open failed: ' .. tostring(ferr) end
    f:write(data); f:close()
    os.remove(path)
    local ok = os.rename(tmp, path)
    if not ok then
        local f2, e2 = io.open(path, 'wb')
        if not f2 then return false, 'rename+rewrite failed: ' .. tostring(e2) end
        f2:write(data); f2:close()
        os.remove(tmp)
    end
    return true
end

-- Returns the HS256 signing secret, or nil + reason when JWT is disabled.
--
-- Single source of truth: the XADMIN_JWT_HS256_SECRET config key, so an
-- upstream API gateway / sidecar can share the exact same secret. We do NOT
-- auto-generate-and-persist a random secret: a server-only random key that no
-- external signer could ever reproduce made the whole JWT path a dead, silently
-- broken feature (and it disagreed with the value /api/session and the startup
-- log report as "JWT enabled"). Unset key == JWT bearer auth disabled.
function M.get_jwt_secret()
    local s = xutils.get_config('XADMIN_JWT_HS256_SECRET', '')
    if type(s) == 'string' and s ~= '' then return s end
    return nil, 'jwt disabled (set XADMIN_JWT_HS256_SECRET)'
end

function M.get_state_secret()
    local cfg = M.load_server_config()
    if type(cfg.oauth_state_secret) == 'string' and cfg.oauth_state_secret ~= '' then
        return cfg.oauth_state_secret
    end
    local s, random_err = M.random_hex(32)
    if not s then return nil, random_err end
    cfg.oauth_state_secret = s
    local ok, err = M.save_server_config(cfg)
    if not ok then return nil, 'persist secret: ' .. tostring(err) end
    return s
end

-- ---------------------------------------------------------------------------
-- OAuth2 provider config
--
-- Convention: XADMIN_OAUTH_<UPPER_NAME>_{CLIENT_ID,CLIENT_SECRET,AUTH_URL,
-- TOKEN_URL,USERINFO_URL,SCOPE,REDIRECT_URI,ISSUER,LABEL,USERNAME_FIELD}.
-- List of configured providers comes from XADMIN_OAUTH_PROVIDERS (comma-
-- separated lower-case names). If only ISSUER is set, the endpoints are
-- resolved via OIDC discovery.
-- ---------------------------------------------------------------------------
local function env(name)
    local v = xutils.get_config(name, '')
    if v == nil or v == '' then return nil end
    return v
end

function M.load_oauth_provider(name)
    name = tostring(name or '')
    if not name:match('^[%w_%-]+$') then return nil, 'invalid provider name' end
    local U = name:upper():gsub('%-', '_')
    local cfg = {
        name         = name,
        label        = env('XADMIN_OAUTH_' .. U .. '_LABEL') or name,
        client_id    = env('XADMIN_OAUTH_' .. U .. '_CLIENT_ID'),
        client_secret= env('XADMIN_OAUTH_' .. U .. '_CLIENT_SECRET'),
        auth_url     = env('XADMIN_OAUTH_' .. U .. '_AUTH_URL'),
        token_url    = env('XADMIN_OAUTH_' .. U .. '_TOKEN_URL'),
        userinfo_url = env('XADMIN_OAUTH_' .. U .. '_USERINFO_URL'),
        scope        = env('XADMIN_OAUTH_' .. U .. '_SCOPE') or 'openid profile email',
        redirect_uri = env('XADMIN_OAUTH_' .. U .. '_REDIRECT_URI'),
        issuer       = env('XADMIN_OAUTH_' .. U .. '_ISSUER'),
        username_field = env('XADMIN_OAUTH_' .. U .. '_USERNAME_FIELD') or 'sub',
        client_auth   = 'body',
        token_encoding= 'form',
    }
    if not cfg.client_id or not cfg.client_secret then
        return nil, 'provider not configured (missing CLIENT_ID / CLIENT_SECRET)'
    end
    if not cfg.auth_url or not cfg.token_url then
        if not cfg.issuer then
            return nil, 'provider needs AUTH_URL + TOKEN_URL, or ISSUER (for OIDC discovery)'
        end
    end
    return cfg
end

-- OIDC discovery: fetch <issuer>/.well-known/openid-configuration, fill in any
-- missing endpoints on `cfg`. `async_http_call` is the worker's async HTTP
-- helper. Returns the same cfg (mutated) on success, nil + reason on failure.
M.discover_oidc = oauth.discover_oidc

-- ---------------------------------------------------------------------------
-- URL helpers (small, kept here to avoid adding a util dependency)
-- ---------------------------------------------------------------------------
M.url_encode       = oauth.url_encode
M.url_encode_query = oauth.url_encode_query
M.form_encode      = oauth.form_encode
M.build_authorize_url = oauth.build_authorize_url
M.exchange_code      = oauth.exchange_code
M.refresh_token      = oauth.refresh_token
M.revoke_token       = oauth.revoke_token

return M
