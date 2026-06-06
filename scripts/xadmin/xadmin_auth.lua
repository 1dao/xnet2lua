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

local xsha2  = dofile('scripts/core/share/xsha2.lua')
local xutils = require('xutils')

local M = {}

local schar = string.char

-- ---------------------------------------------------------------------------
-- Randomness (use the OS CSPRNG, fall back to /dev/urandom, then math.random)
-- ---------------------------------------------------------------------------
local _urandom_seeded = false
local function random_bytes(n)
    n = tonumber(n) or 0
    if n <= 0 then return '' end
    if type(xnet) == 'table' and xnet.random_bytes then
        local b = xnet.random_bytes(n)
        if type(b) == 'string' and #b == n then return b end
    end
    local f = io.open('/dev/urandom', 'rb')
    if f then
        local raw = f:read(n)
        f:close()
        if type(raw) == 'string' and #raw == n then return raw end
    end
    if not _urandom_seeded then
        math.randomseed(os.time() + (os.clock() * 1e6) % 1e9)
        _urandom_seeded = true
    end
    local out = {}
    for i = 1, n do out[i] = schar(math.random(0, 255)) end
    return table.concat(out)
end

function M.random_bytes(n) return random_bytes(n) end
function M.random_hex(n)   return xsha2.tohex(random_bytes(n or 16)) end

-- URL-safe random string (A-Z a-z 0-9 - _ . ~) suitable for state, nonce,
-- code_verifier. Encodes random bytes with the standard base64url alphabet
-- and truncates to the requested length. The truncation discards at most 4
-- bits of the last byte (no bias; each 6-bit window is independent and
-- uniformly distributed over 0-63 when the input bytes are uniform).
function M.random_urlsafe(n)
    n = tonumber(n) or 32
    if n <= 0 then return '' end
    local bytes = math.ceil(n * 3 / 4)
    local s = M.b64url_encode(random_bytes(bytes))
    return s:sub(1, n)
end

-- ---------------------------------------------------------------------------
-- base64url (no padding) -- JWS / JWT / PKCE standard
-- ---------------------------------------------------------------------------
local B64URL = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
local _b64_rev = nil
local function b64_reverse_map()
    if _b64_rev then return _b64_rev end
    local m = {}
    for i = 1, #B64URL do m[B64URL:sub(i, i)] = i - 1 end
    -- Tolerate standard alphabet too (RFC 7515 implementations vary).
    for i = 0, 25 do m[schar(65 + i)] = i end
    for i = 0, 25 do m[schar(97 + i)] = 26 + i end
    for i = 0, 9  do m[tostring(i)]   = 52 + i end
    m['+'] = 62; m['/'] = 63
    _b64_rev = m
    return m
end

function M.b64url_encode(s)
    s = tostring(s or '')
    if s == '' then return '' end
    local out = {}
    local n = #s
    local i = 1
    while i <= n do
        local b1 = s:byte(i)     or 0
        local b2 = s:byte(i + 1) or 0
        local b3 = s:byte(i + 2) or 0
        local c1 = b1 >> 2
        local c2 = ((b1 & 3) << 4) | (b2 >> 4)
        local c3 = ((b2 & 15) << 2) | (b3 >> 6)
        local c4 = b3 & 63
        out[#out + 1] = B64URL:sub(c1 + 1, c1 + 1)
        out[#out + 1] = B64URL:sub(c2 + 1, c2 + 1)
        out[#out + 1] = (i + 1 <= n) and B64URL:sub(c3 + 1, c3 + 1) or ''
        out[#out + 1] = (i + 2 <= n) and B64URL:sub(c4 + 1, c4 + 1) or ''
        i = i + 3
    end
    return table.concat(out)
end

function M.b64url_decode(s)
    s = tostring(s or ''):gsub('=', '')  -- tolerate padding
    if s == '' then return '' end
    local rev = b64_reverse_map()
    local out = {}
    local n = #s
    local i = 1
    while i <= n do
        local v1 = rev[s:sub(i,     i    )] or 0
        local v2 = rev[s:sub(i + 1, i + 1)] or 0
        local have3 = (i + 2) <= n
        local have4 = (i + 3) <= n
        local v3 = have3 and (rev[s:sub(i + 2, i + 2)] or 0) or nil
        local v4 = have4 and (rev[s:sub(i + 3, i + 3)] or 0) or nil
        out[#out + 1] = schar((v1 << 2) | (v2 >> 4))
        if v3 then out[#out + 1] = schar(((v2 & 15) << 4) | (v3 >> 2)) end
        if v4 then out[#out + 1] = schar(((v3 & 3)  << 6) | v4)       end
        i = i + 4
    end
    return table.concat(out)
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
    local sig = M.b64url_encode(xsha2.hmac_sha256(secret, signing_input))
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
    local expected = M.b64url_encode(xsha2.hmac_sha256(secret, signing_input))
    if not xsha2.equal(parts[3], expected) then return nil, 'bad signature' end

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

-- ---------------------------------------------------------------------------
-- PKCE S256 (RFC 7636) -- used by OAuth2 Authorization Code flow
-- ---------------------------------------------------------------------------
function M.pkce_pair()
    local verifier = M.random_urlsafe(64)   -- 64 chars, 384 bits of entropy
    local challenge = M.b64url_encode(xsha2.sha256(verifier))
    return verifier, challenge
end

-- ---------------------------------------------------------------------------
-- Self-contained signed OAuth2 state.
--
-- Avoids a server-side state store (no Redis/DB table needed for the
-- short-lived round-trip). Format: <b64url(json claims)>.<b64url(hmac)>.
-- Claims include: p=provider, n=nonce, exp, next=return_to. The PKCE
-- code_verifier is intentionally NOT here -- it must stay secret and is carried
-- in an HttpOnly cookie instead (see xadmin_app cv_cookie), since the state
-- round-trips through the IdP and the redirect URL.
-- ---------------------------------------------------------------------------
function M.sign_state(secret, claims)
    if not secret or secret == '' then return nil, 'no state secret' end
    local payload = xutils.json_pack(claims or {})
    if not payload then return nil, 'json pack failed' end
    local p64 = M.b64url_encode(payload)
    local sig = M.b64url_encode(xsha2.hmac_sha256(secret, p64))
    return p64 .. '.' .. sig
end

function M.verify_state(secret, token)
    if not secret or secret == '' then return nil, 'no state secret' end
    token = tostring(token or '')
    local p64, sig = token:match('^(.+)%.(.+)$')
    if not p64 then return nil, 'malformed' end
    local expected = M.b64url_encode(xsha2.hmac_sha256(secret, p64))
    if not xsha2.equal(sig, expected) then return nil, 'bad signature' end
    local payload = M.b64url_decode(p64)
    local claims = xutils.json_unpack(payload)
    if type(claims) ~= 'table' then return nil, 'bad json' end
    local exp = tonumber(claims.exp) or 0
    if os.time() > exp then return nil, 'expired' end
    return claims
end

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
    local s = M.random_hex(32)
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
function M.discover_oidc(cfg, async_http_call)
    if not cfg.issuer or cfg.issuer == '' then return cfg end
    if cfg.auth_url and cfg.token_url then return cfg end   -- already complete
    local url = cfg.issuer:gsub('/+$', '') .. '/.well-known/openid-configuration'
    local err, resp = async_http_call({
        method = 'GET',
        url = url,
        timeout_ms = 5000,
        decompress = true,
    })
    if err then return nil, 'oidc discovery: ' .. tostring(err) end
    if not resp or resp.status ~= 200 then
        return nil, 'oidc discovery http ' .. tostring(resp and resp.status)
    end
    local doc = xutils.json_unpack(resp.body or '')
    if type(doc) ~= 'table' then return nil, 'oidc discovery: bad json' end
    cfg.auth_url     = cfg.auth_url     or doc.authorization_endpoint
    cfg.token_url    = cfg.token_url    or doc.token_endpoint
    cfg.userinfo_url = cfg.userinfo_url or doc.userinfo_endpoint
    cfg.issuer       = cfg.issuer       or doc.issuer
    if not cfg.auth_url or not cfg.token_url then
        return nil, 'oidc discovery: missing endpoints'
    end
    return cfg
end

-- ---------------------------------------------------------------------------
-- URL helpers (small, kept here to avoid adding a util dependency)
-- ---------------------------------------------------------------------------
function M.url_encode(s)
    s = tostring(s or '')
    if s == '' then return '' end
    local out = {}
    for i = 1, #s do
        local b = s:byte(i)
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57)
            or b == 45 or b == 95 or b == 46 or b == 126 then
            out[#out + 1] = s:sub(i, i)
        else
            out[#out + 1] = string.format('%%%02X', b)
        end
    end
    return table.concat(out)
end

function M.url_encode_query(t)
    local out = {}
    for k, v in pairs(t or {}) do
        out[#out + 1] = M.url_encode(k) .. '=' .. M.url_encode(v)
    end
    return table.concat(out, '&')
end

-- Form-encode a body for application/x-www-form-urlencoded.
function M.form_encode(t)
    return M.url_encode_query(t)
end

return M
