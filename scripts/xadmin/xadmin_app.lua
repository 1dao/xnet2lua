-- xadmin_app.lua - HTTP routes for the xadmin console.
--
-- Each fd has one session coroutine managed by xadmin_worker/xsession.
-- That means routes can call yielding APIs (notably xnats.rpc/xthread.rpc) and just
-- `return` the response synchronously; xnats.rpc routes self-targeted calls
-- straight to the local business worker (caller-side short-circuit) and
-- only goes over NATS for cross-process targets.
--
-- xnats.rpc unified return shape (used here):
--   channel_ok = false   → (false, channel_err)
--   channel_ok = true    → (true, app_ok, app_ret1, app_ret2, ...)

local router = dofile('scripts/core/share/xhttp_router.lua')
local store  = dofile('scripts/xadmin/xadmin_store.lua')
local auth   = dofile('scripts/xadmin/xadmin_auth.lua')
local xutils = require('xutils')

local STATIC_DIR = xutils.get_config('XADMIN_STATIC_DIR', 'scripts/xadmin/static')
local TOKEN = xutils.get_config('XADMIN_TOKEN', '')
-- Master bypass token: any request carrying it skips authentication entirely
-- (and the "not configured" gate). Empty disables the feature. Keep it secret
-- and prefer HTTPS, since it grants unconditional access.
local SUPER_TOKEN = xutils.get_config('XADMIN_SUPER_TOKEN', '')
-- DEV-ONLY kill switch. When truthy, ALL authentication and authorization is
-- disabled: every request is treated as an admin, the login/setup gate is
-- skipped, and JWT/OAuth/mTLS/role checks are bypassed. For frictionless local
-- testing only -- NEVER set this in any real deployment.
local function cfg_truthy(v)
    v = tostring(v or ''):lower()
    return v == '1' or v == 'true' or v == 'yes' or v == 'on'
end
local DEV_NO_AUTH = cfg_truthy(xutils.get_config('XADMIN_DEV_NO_AUTH', '0'))
local SESSION_COOKIE = 'xadmin_sid'
local SESSION_MAX_AGE = 7 * 24 * 3600
-- Public host:port, used only to synthesize an OAuth redirect_uri when the
-- request carries no Host header (HTTP/1.0 probes, some proxies). Read from the
-- same config keys MAIN uses; the bare HTTP_HOST/HTTP_PORT globals do NOT exist
-- in worker Lua states, so referencing them would raise on a missing Host.
local PUBLIC_HOST = xutils.get_config('XADMIN_HOST', '127.0.0.1')
local PUBLIC_PORT = tostring(xutils.get_config('XADMIN_PORT', '18090'))

local M = {}

-- Worker-local context populated by xadmin_worker via M.setup. Routes read
-- through this table at call time so that hot-reload of xadmin_worker can
-- refresh the helpers without needing to re-register the routes.
local ctx = {
    self_name      = '',
    token_required = TOKEN ~= '',
    alive_peers    = function() return {} end,
    now_ms         = function() return math.floor(os.time() * 1000) end,
}

function M.setup(c)
    if type(c) ~= 'table' then return end
    for k, v in pairs(c) do ctx[k] = v end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local unpack_args = table.unpack or unpack

local function pack_values(...)
    return { n = select('#', ...), ... }
end

local function plain(status, body, content_type)
    return {
        status = status,
        body = body or '',
        headers = {
            ['Content-Type'] = content_type or 'text/plain; charset=utf-8',
            ['Cache-Control'] = 'no-store',
        },
    }
end

local function json(status, payload)
    local body, err = xutils.json_pack(payload)
    if not body then return plain(500, 'json pack failed: ' .. tostring(err)) end
    return {
        status = status,
        body = body,
        headers = {
            ['Content-Type'] = 'application/json; charset=utf-8',
            ['Cache-Control'] = 'no-store',
        },
    }
end

local function file_response(path, content_type)
    return {
        status = 200,
        file = path,
        headers = {
            ['Content-Type'] = content_type or 'application/octet-stream',
            ['Cache-Control'] = 'no-store',
        },
    }
end

local function header_get(req, name)
    local h = req.headers or {}
    -- xhttp_codec lowercases header names; tolerate both anyway.
    return h[name] or h[name:lower()] or h[name:upper()]
end

local function check_token(req)
    if DEV_NO_AUTH then return true end
    if TOKEN == '' then return true end
    local got = header_get(req, 'X-Xadmin-Token') or header_get(req, 'x-xadmin-token')
    if got == TOKEN then return true end
    return false
end

-- True when the request carries the master bypass token. Accepted either via a
-- dedicated X-Xadmin-Super-Token header or the regular X-Xadmin-Token header.
local function is_super(req)
    if SUPER_TOKEN == '' then return false end
    local got = header_get(req, 'X-Xadmin-Super-Token') or header_get(req, 'X-Xadmin-Token')
    return got ~= nil and got == SUPER_TOKEN
end

-- ---------------------------------------------------------------------------
-- Cookie / session helpers
-- ---------------------------------------------------------------------------
local function get_cookie(req, name)
    local raw = header_get(req, 'cookie')
    if not raw then return nil end
    for pair in tostring(raw):gmatch('[^;]+') do
        local k, v = pair:match('^%s*([^=]+)=(.*)$')
        if k == name then return v end
    end
    return nil
end

local function session_cookie(token, max_age)
    -- Lax SameSite + HttpOnly; no Secure flag since the console is commonly
    -- served over plain HTTP on localhost.
    return string.format('%s=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=%d',
        SESSION_COOKIE, token, max_age)
end

-- ---------------------------------------------------------------------------
-- Authorization (role) -- authentication answers "who", this answers "what".
--
-- Without this layer every authenticated principal (including any CA-signed
-- mTLS cert and every auto-provisioned SSO user) could reach /api/exec, i.e.
-- run arbitrary Lua on the whole cluster. We grant 'admin' only to the trusted
-- local paths (password session, super token, X-Xadmin-Token) and to names the
-- operator explicitly lists; federated identities default to read-only.
-- ---------------------------------------------------------------------------
local function split_csv_set(raw)
    local set = {}
    for n in tostring(raw or ''):gmatch('[^,]+') do
        local s = n:match('^%s*(.-)%s*$')
        if s and s ~= '' then set[s] = true end
    end
    return set
end

-- Names that get the 'admin' role: XADMIN_ADMINS (comma-separated) plus the
-- setup admin persisted in xadmin_db.json. A federated identity becomes admin
-- only if its resolved local name appears here -- that is what stops "any SSO
-- account / any client cert" from reaching the dangerous endpoints.
local function admin_names(db_cfg)
    local set = split_csv_set(xutils.get_config('XADMIN_ADMINS', ''))
    if db_cfg and db_cfg.admin_user and db_cfg.admin_user ~= '' then
        set[db_cfg.admin_user] = true
    end
    return set
end

local function role_for(name, db_cfg)
    return admin_names(db_cfg)[name] and 'admin' or 'viewer'
end

local function require_admin(req)
    return req.xadmin_role == 'admin'
end

-- A JWT may carry an explicit `role` claim ('admin'|'viewer'). It is trusted
-- because the token is signed with the server secret (only an admin can mint one
-- via /api/tokens). Returns the validated role, or nil to fall back to the
-- XADMIN_ADMINS allowlist (role_for) for tokens without a role claim.
local function claim_role(claims)
    local rc = claims and claims.role
    return (rc == 'admin' or rc == 'viewer') and rc or nil
end

-- Resolve the authenticated principal for a request.
-- Returns (name, role). `name` is the username for a valid session cookie, the
-- literal 'token' for a matching X-Xadmin-Token, the 'mtls:<subject>' label (or
-- linked local_user) for a verified mTLS client, or the JWT subject / its link.
-- `role` is 'admin' or 'viewer'. Returns nil when unauthenticated.
local function current_user(req, db_cfg)
    if is_super(req) then return 'super', 'admin' end

    -- mTLS: the transport stashes the verified peer cert's subject DN on
    -- req.peer_cert_subject when XADMIN_TLS_CA_FILE is set and the handshake
    -- completed successfully. The subject is the raw DN string from mbedtls
    -- (e.g. "CN=client1,O=My Org"). Admins can pin a subject to a local
    -- account via the oauth_links table; otherwise the full DN is used as
    -- the principal name.
    if req.peer_cert_subject and req.peer_cert_subject ~= '' then
        local mapped = store.lookup_oauth_link(db_cfg.db.database, 'mtls',
                                               req.peer_cert_subject)
        local name = mapped or ('mtls:' .. req.peer_cert_subject)
        return name, role_for(name, db_cfg)
    end

    -- JWT bearer (Authorization: Bearer <jwt>). HS256 only; iss/aud/exp/nbf
    -- are validated against the configured expected values. The 'sub' claim
    -- becomes the local username. The user must exist in the accounts table
    -- (or be linked via oauth_links) -- we don't auto-provision.
    local bearer = header_get(req, 'authorization')
    if bearer and bearer:lower():find('^bearer%s+') then
        local tok = bearer:sub(8)
        local secret = auth.get_jwt_secret()
        if secret then
            local iss = xutils.get_config('XADMIN_JWT_ISSUER', nil)
            local aud = xutils.get_config('XADMIN_JWT_AUDIENCE', 'xadmin')
            -- '*' is treated as "no check" so default configs are open enough
            -- for first-try deployments. Set ISSUER / AUDIENCE to lock down.
            local iss_opt = (iss and iss ~= '' and iss ~= '*') and iss or nil
            local aud_opt = (aud and aud ~= '' and aud ~= '*') and aud or nil
            local claims, jerr = auth.jwt_verify_hs256(secret, tok, {
                iss = iss_opt, aud = aud_opt, leeway = 30,
            })
            if claims and claims.sub and claims.sub ~= '' then
                -- Honour explicit links first (let the admin pin a JWT sub to
                -- a local account), then fall back to the raw 'sub' claim.
                local mapped = store.lookup_oauth_link(db_cfg.db.database, 'jwt', claims.sub)
                local name = mapped or tostring(claims.sub)
                return name, claim_role(claims) or role_for(name, db_cfg)
            end
        end
    end

    local token = get_cookie(req, SESSION_COOKIE)
    if token and token ~= '' then
        local user, role = store.validate_session(db_cfg.db.database, token)
        if user then return user, role or role_for(user, db_cfg) end
    end
    if TOKEN ~= '' and check_token(req) then
        return 'token', 'admin'
    end
    return nil
end

-- "name" or "name:idx" → "name:idx" (default idx=1).
local function resolve_rpc_target(name)
    name = tostring(name or '')
    if name == '' or name == 'self' then name = ctx.self_name or '' end
    if name == '' then return nil, 'no target' end
    if name:match(':%d+$') then return name end
    return name .. ':1', nil, name
end

-- ---------------------------------------------------------------------------
-- Router setup
-- ---------------------------------------------------------------------------
router.reset({
    file_response = file_response,
    log_prefix = 'XADMIN',
    not_found = function() return plain(404, 'not found\n') end,
})

M.route = router.reg
M.router = router

router.reg_path(STATIC_DIR, { index = 'index.html', index_route = '/' })

-- ---------------------------------------------------------------------------
-- Auth / setup (public endpoints; gating is enforced in M.handle)
-- ---------------------------------------------------------------------------

-- Report whether the console has been configured and whether the caller is
-- authenticated. The SPA uses this to pick which view to render and which
-- login buttons to show. `auth_methods` enumerates everything that is
-- currently usable in this deployment, so the UI can adapt without hardcoding.
router.reg('get', '/api/session', function(req)
    if DEV_NO_AUTH then
        return json(200, {
            self = ctx.self_name or '',
            configured = true,        -- skip the setup gate in the SPA
            authenticated = true,
            username = 'dev',
            role = 'admin',
            token_required = false,
            dev_no_auth = true,
            auth_methods = {},
        })
    end
    local cfg = store.load_db_config()
    local methods = { password = cfg.configured and true or false }
    if req.peer_cert_subject and req.peer_cert_subject ~= '' then
        methods.mtls = true
    end
    if xutils.get_config('XADMIN_JWT_HS256_SECRET', '') ~= '' then
        methods.jwt = true
    end
    local oauth_list = store.list_oauth_providers()
    if #oauth_list > 0 then methods.oauth = oauth_list end

    local resp = {
        self           = ctx.self_name or '',
        configured     = cfg.configured and true or false,
        db_from_cfg    = cfg.db_from_cfg and true or false,
        token_required = ctx.token_required and true or false,
        authenticated  = false,
        username       = nil,
        role           = nil,
        auth_methods   = methods,
    }
    if is_super(req) then
        resp.authenticated = true
        resp.username = 'super'
        resp.role = 'admin'
    elseif cfg.configured then
        local user, role = current_user(req, cfg)
        if user then
            resp.authenticated = true
            resp.username = user
            resp.role = role
        end
    end
    return json(200, resp)
end)

-- First-time setup: validate the DB credentials, create the schema and the
-- default admin account, persist the connection settings, then log the caller
-- in. Allowed only while unconfigured (enforced here and in M.handle).
router.reg('post', '/api/setup', function(req)
    local cfg = store.load_db_config()
    if cfg.configured then
        return json(409, { ok = false, error = 'already configured' })
    end

    local body = xutils.json_unpack(req.body or '')
    if type(body) ~= 'table' then
        return json(400, { ok = false, error = 'invalid json body' })
    end

    -- When xnet.cfg fully specifies the DB, use it and ignore any DB fields in
    -- the form; otherwise take the connection settings from the setup form.
    local db
    if cfg.db_from_cfg then
        db = store.normalize_db(cfg.db)
    else
        db = store.normalize_db({
            host = body.host, port = body.port, user = body.user,
            password = body.password, database = body.database,
        })
    end
    local admin_user = tostring(body.admin_user or '')
    local admin_pass = tostring(body.admin_pass or '')
    if admin_user == '' or admin_pass == '' then
        return json(400, { ok = false, error = 'admin username and password are required' })
    end

    -- Ask the main thread to (re)start the MySQL pool with these credentials.
    local rok, rerr = xthread.rpc(xthread.MAIN, 'xadmin_db_apply', 8000,
        db.host, db.port, db.user, db.password)
    if not rok then
        return json(502, { ok = false, error = 'mysql start failed: ' .. tostring(rerr) })
    end

    local ok, err = store.ensure_schema(db.database)
    if not ok then
        return json(502, { ok = false, error = 'cannot reach database: ' .. tostring(err) })
    end

    ok, err = store.upsert_account(db.database, admin_user, admin_pass)
    if not ok then
        return json(500, { ok = false, error = 'create admin failed: ' .. tostring(err) })
    end

    local saved, serr = store.save_db_config({
        configured = true, db = db, admin_user = admin_user,
    })
    if not saved then
        return json(500, { ok = false, error = 'save config failed: ' .. tostring(serr) })
    end

    local token = store.create_session(db.database, admin_user, 'admin')
    local headers = {
        ['Content-Type'] = 'application/json; charset=utf-8',
        ['Cache-Control'] = 'no-store',
    }
    if token then headers['Set-Cookie'] = session_cookie(token, SESSION_MAX_AGE) end
    return {
        status = 200,
        body = xutils.json_pack({ ok = true, username = admin_user, role = 'admin', database = db.database }),
        headers = headers,
    }
end)

router.reg('post', '/api/login', function(req)
    local cfg = store.load_db_config()
    if not cfg.configured then
        return json(409, { ok = false, error = 'not configured', need = 'setup' })
    end
    local body = xutils.json_unpack(req.body or '')
    if type(body) ~= 'table' then
        return json(400, { ok = false, error = 'invalid json body' })
    end
    local username = tostring(body.username or '')
    local password = tostring(body.password or '')
    if username == '' or password == '' then
        return json(400, { ok = false, error = 'username and password are required' })
    end

    local ok, who = store.verify_login(cfg.db.database, username, password)
    if not ok then
        return json(401, { ok = false, error = 'invalid username or password' })
    end

    local token, terr = store.create_session(cfg.db.database, who, role_for(who, cfg))
    if not token then
        return json(500, { ok = false, error = 'create session failed: ' .. tostring(terr) })
    end
    return {
        status = 200,
        body = xutils.json_pack({ ok = true, username = who, role = role_for(who, cfg) }),
        headers = {
            ['Content-Type'] = 'application/json; charset=utf-8',
            ['Cache-Control'] = 'no-store',
            ['Set-Cookie'] = session_cookie(token, SESSION_MAX_AGE),
        },
    }
end)

router.reg('post', '/api/logout', function(req)
    local cfg = store.load_db_config()
    local token = get_cookie(req, SESSION_COOKIE)
    if cfg.configured and token and token ~= '' then
        store.destroy_session(cfg.db.database, token)
    end
    return {
        status = 200,
        body = xutils.json_pack({ ok = true }),
        headers = {
            ['Content-Type'] = 'application/json; charset=utf-8',
            ['Cache-Control'] = 'no-store',
            -- Expire the cookie immediately.
            ['Set-Cookie'] = session_cookie('', 0),
        },
    }
end)

-- ---------------------------------------------------------------------------
-- Federated identity: OAuth2 Authorization Code + PKCE
--
-- The session gate in M.handle is open for /api/auth/oauth/* so unauthenticated
-- users can complete an SSO login. Both /start and /callback build a 302
-- redirect: /start also sets the short-lived PKCE cv cookie, and /callback sets
-- the session cookie after a successful code exchange. State is HMAC-signed by
-- the server (see xadmin_auth.sign_state) so we don't need a server-side store.
-- ---------------------------------------------------------------------------
local function oauth_redirect(location)
    return {
        status = 302,
        body = '',
        headers = { Location = location, ['Cache-Control'] = 'no-store' },
    }
end

-- Open-redirect guard for the `next` return path. Only same-origin absolute
-- paths are allowed; reject empty, protocol-relative ('//host') and absolute
-- ('scheme://host') URLs so a crafted callback URL can't bounce the victim to
-- an attacker site (with a fake 'SSO failed' banner). Returns the safe path or
-- nil. NB: the success redirect uses the *signed* state's next, but the error
-- branches reflect the raw query `next`, which is attacker-controlled.
local function safe_next(next)
    next = tostring(next or '')
    if next == '/' then return '/' end
    if next:match('^/[^/\\]') then return next end
    return nil
end

local function oauth_error(msg, status, next)
    status = status or 400
    local dest = safe_next(next)
    if dest then
        -- Carry the error back as a query string when we can redirect.
        return oauth_redirect(dest .. (dest:find('?') and '&' or '?') ..
            'auth_error=' .. auth.url_encode(msg))
    end
    return json(status, { ok = false, error = msg })
end

-- PKCE code_verifier transport (B3). The verifier MUST stay secret -- it is the
-- proof of possession that makes PKCE meaningful -- so it is never placed in the
-- OAuth `state` (which round-trips through the IdP and the redirect URL, where
-- it would leak via logs/referer/history). Instead /start stashes it in a
-- short-lived, HttpOnly, path-scoped cookie the browser returns only to the
-- callback; SameSite=Lax still sends it on the top-level redirect navigation
-- back from the IdP. Keyed by provider so concurrent logins don't collide.
local OAUTH_CV_PREFIX = 'xadmin_ocv_'
local function cv_cookie(provider, value, max_age)
    return string.format('%s%s=%s; Path=/api/auth/oauth; HttpOnly; SameSite=Lax; Max-Age=%d',
        OAUTH_CV_PREFIX, provider, value, max_age)
end

router.reg('get', '/api/auth/oauth/:provider/start', function(req)
    local cfg = store.load_db_config()
    if not cfg.configured then
        return oauth_error('not configured', 409, req.query and req.query.next)
    end
    local provider = tostring(req.params and req.params.provider or '')
    local pcfg, perr = auth.load_oauth_provider(provider)
    if not pcfg then return oauth_error(perr, 400, req.query and req.query.next) end

    -- OIDC discovery: only needed if the admin didn't pin AUTH_URL/TOKEN_URL.
    pcfg, perr = auth.discover_oidc(pcfg, ctx.async_http_call)
    if not pcfg then return oauth_error(perr, 502, req.query and req.query.next) end

    local verifier, challenge = auth.pkce_pair()
    local state_secret, serr = auth.get_state_secret()
    if not state_secret then return oauth_error(serr or 'state secret', 500) end

    local next_path = safe_next(req.query and req.query.next) or '/'  -- open-redirect guard

    -- NB: the code_verifier is deliberately NOT in the state -- it travels in
    -- the cv cookie set on the response below (see cv_cookie / B3).
    local state = auth.sign_state(state_secret, {
        p  = provider,
        n  = auth.random_urlsafe(16),
        exp = os.time() + 600,                -- 10 min round-trip budget
        next = next_path,
    })
    if not state then return oauth_error('sign state', 500) end

    if not pcfg.redirect_uri or pcfg.redirect_uri == '' then
        -- Default redirect URI assumes xadmin is on the same host:port as
        -- the public URL. Admins with reverse proxies should set
        -- XADMIN_OAUTH_<NAME>_REDIRECT_URI explicitly.
        local scheme = (header_get(req, 'x-forwarded-proto') or 'http'):lower()
        local host = header_get(req, 'host') or (PUBLIC_HOST .. ':' .. PUBLIC_PORT)
        pcfg.redirect_uri = scheme .. '://' .. host ..
            '/api/auth/oauth/' .. provider .. '/callback'
    end

    local auth_url = pcfg.auth_url
        .. (pcfg.auth_url:find('?', 1, true) and '&' or '?')
        .. auth.url_encode_query({
            response_type         = 'code',
            client_id             = pcfg.client_id,
            redirect_uri          = pcfg.redirect_uri,
            scope                 = pcfg.scope,
            state                 = state,
            code_challenge        = challenge,
            code_challenge_method = 'S256',
        })
    return {
        status = 302,
        body = '',
        headers = {
            Location = auth_url,
            ['Set-Cookie'] = cv_cookie(provider, verifier, 600),
            ['Cache-Control'] = 'no-store',
        },
    }
end)

router.reg('get', '/api/auth/oauth/:provider/callback', function(req)
    local cfg = store.load_db_config()
    if not cfg.configured then
        return oauth_error('not configured', 409, req.query and req.query.next)
    end
    local provider = tostring(req.params and req.params.provider or '')
    local q = req.query or {}
    local code  = tostring(q.code  or '')
    local state = tostring(q.state or '')
    if code == '' then return oauth_error('missing code', 400, q.next) end
    if state == '' then return oauth_error('missing state', 400, q.next) end

    local state_secret = auth.get_state_secret()
    local claims, serr = auth.verify_state(state_secret, state)
    if not claims then return oauth_error('bad state: ' .. tostring(serr), 400, q.next) end
    if tostring(claims.p or '') ~= provider then
        return oauth_error('state/provider mismatch', 400, q.next)
    end

    -- PKCE verifier comes from the cookie /start set, not from the state (B3).
    local verifier = get_cookie(req, OAUTH_CV_PREFIX .. provider)
    if not verifier or verifier == '' then
        return oauth_error('missing pkce verifier (expired or third-party cookies blocked)',
            400, q.next)
    end

    local pcfg, perr = auth.load_oauth_provider(provider)
    if not pcfg then return oauth_error(perr, 400, q.next) end
    pcfg, perr = auth.discover_oidc(pcfg, ctx.async_http_call)
    if not pcfg then return oauth_error(perr, 502, q.next) end

    if not pcfg.redirect_uri or pcfg.redirect_uri == '' then
        local scheme = (header_get(req, 'x-forwarded-proto') or 'http'):lower()
        local host = header_get(req, 'host') or (PUBLIC_HOST .. ':' .. PUBLIC_PORT)
        pcfg.redirect_uri = scheme .. '://' .. host ..
            '/api/auth/oauth/' .. provider .. '/callback'
    end

    -- Exchange authorization code for access_token (+ id_token if provided).
    local tok_err, tok_resp = ctx.async_http_call({
        method  = 'POST',
        url     = pcfg.token_url,
        headers = {
            ['Content-Type'] = 'application/x-www-form-urlencoded',
            ['Accept']       = 'application/json',
        },
        body = auth.form_encode({
            grant_type    = 'authorization_code',
            code          = code,
            client_id     = pcfg.client_id,
            client_secret = pcfg.client_secret,
            redirect_uri  = pcfg.redirect_uri,
            code_verifier = verifier,
        }),
        timeout_ms = 8000,
    })
    if tok_err then return oauth_error('token exchange: ' .. tostring(tok_err), 502, q.next) end
    if not tok_resp or tok_resp.status < 200 or tok_resp.status >= 300 then
        return oauth_error('token http ' .. tostring(tok_resp and tok_resp.status), 502, q.next)
    end
    local tok = xutils.json_unpack(tok_resp.body or '')
    if type(tok) ~= 'table' or not tok.access_token then
        return oauth_error('token response missing access_token', 502, q.next)
    end
    local access_token = tostring(tok.access_token)

    -- Determine the external subject. Preferred order:
    --   1) userinfo endpoint (authenticated by access_token)
    --   2) id_token 'sub' claim from the token response
    -- The OAuth links table then maps the subject to a local account.
    local external_sub, userinfo
    if pcfg.userinfo_url and pcfg.userinfo_url ~= '' then
        local u_err, u_resp = ctx.async_http_call({
            method  = 'GET',
            url     = pcfg.userinfo_url,
            headers = { ['Authorization'] = 'Bearer ' .. access_token,
                        ['Accept']        = 'application/json' },
            timeout_ms = 5000,
        })
        if not u_err and u_resp and u_resp.status == 200 then
            userinfo = xutils.json_unpack(u_resp.body or '')
        end
    end
    if userinfo and type(userinfo) == 'table' then
        external_sub = tostring(userinfo[pcfg.username_field] or userinfo.sub or '')
    end
    if external_sub == '' and tok.id_token and tok.id_token ~= '' then
        -- We don't verify the id_token signature (RS256 unsupported in this
        -- build); just decode the payload to read the 'sub' claim. Strict
        -- verification is the caller's responsibility when the IdP signs
        -- with HS256 -- they can POST the id_token to /api/auth/jwt instead.
        local parts = {}
        for p in tostring(tok.id_token):gmatch('[^.]+') do parts[#parts + 1] = p end
        if #parts == 3 then
            local pl = xutils.json_unpack(auth.b64url_decode(parts[2]))
            if type(pl) == 'table' then
                external_sub = tostring(pl.sub or '')
            end
        end
    end
    if external_sub == '' then
        return oauth_error('could not determine subject', 502, q.next)
    end

    -- Map external subject to a local account. If no explicit link is
    -- configured, the 'sub' is used as the username directly. The local
    -- account is auto-provisioned (idempotent) so first-time SSO users
    -- don't have to be pre-created in the accounts table; a random
    -- password is set that they cannot use to log in via /api/login.
    local username = store.lookup_oauth_link(cfg.db.database, provider, external_sub)
    if not username then
        username = external_sub
        if not username:match('^[%w_%.@%-]+$') or #username > 64 then
            return oauth_error('subject unusable as username: ' .. external_sub, 400, q.next)
        end
        -- Provision a placeholder account. We do NOT set a known password
        -- (so /api/login rejects the user); only federated login works.
        store.upsert_account(cfg.db.database, username, auth.random_hex(16))
        store.upsert_oauth_link(cfg.db.database, provider, external_sub, username)
    end

    local session, terr = store.create_session(cfg.db.database, username, role_for(username, cfg))
    if not session then
        return oauth_error('create session: ' .. tostring(terr), 500, q.next)
    end
    return {
        status = 302,
        body = '',
        headers = {
            Location = safe_next(claims.next) or '/',
            ['Set-Cookie'] = session_cookie(session, SESSION_MAX_AGE),
            ['Cache-Control'] = 'no-store',
        },
    }
end)

-- ---------------------------------------------------------------------------
-- JWT (HS256) login: exchange a verified bearer token for a session cookie.
-- Useful when an API gateway / sidecar already authenticated the user and
-- forwards an HS256-signed assertion. For RS256, front xadmin with such a
-- gateway and have it sign HS256 for xadmin; the gateway owns the RSA key.
-- ---------------------------------------------------------------------------
router.reg('post', '/api/auth/jwt', function(req)
    local cfg = store.load_db_config()
    if not cfg.configured then
        return json(409, { ok = false, error = 'not configured' })
    end
    local body = xutils.json_unpack(req.body or '')
    if type(body) ~= 'table' then
        return json(400, { ok = false, error = 'invalid json' })
    end
    local token = tostring(body.token or '')
    -- Also accept the token in the Authorization header for one-shot exchange.
    if token == '' then
        local authz = header_get(req, 'authorization')
        if authz and authz:lower():find('^bearer%s+') then
            token = authz:sub(8)
        end
    end
    if token == '' then
        return json(400, { ok = false, error = 'token is required' })
    end
    local secret, serr = auth.get_jwt_secret()
    if not secret then return json(403, { ok = false, error = serr or 'jwt disabled' }) end

    local iss = xutils.get_config('XADMIN_JWT_ISSUER', nil)
    local aud = xutils.get_config('XADMIN_JWT_AUDIENCE', 'xadmin')
    local iss_opt = (iss and iss ~= '' and iss ~= '*') and iss or nil
    local aud_opt = (aud and aud ~= '' and aud ~= '*') and aud or nil
    local claims, jerr = auth.jwt_verify_hs256(secret, token, {
        iss = iss_opt, aud = aud_opt, leeway = 30,
    })
    if not claims then return json(401, { ok = false, error = 'jwt: ' .. tostring(jerr) }) end
    local sub = tostring(claims.sub or '')
    if sub == '' then return json(401, { ok = false, error = 'jwt: no sub claim' }) end

    local username = store.lookup_oauth_link(cfg.db.database, 'jwt', sub) or sub
    if not username:match('^[%w_%.@%-]+$') or #username > 64 then
        return json(400, { ok = false, error = 'subject unusable as username' })
    end
    if not store.lookup_oauth_link(cfg.db.database, 'jwt', sub) then
        -- Auto-provision: see OAuth callback for rationale.
        store.upsert_account(cfg.db.database, username, auth.random_hex(16))
        store.upsert_oauth_link(cfg.db.database, 'jwt', sub, username)
    end

    local role = claim_role(claims) or role_for(username, cfg)
    local session, terr = store.create_session(cfg.db.database, username, role)
    if not session then
        return json(500, { ok = false, error = 'create session: ' .. tostring(terr) })
    end
    return {
        status = 200,
        body = xutils.json_pack({ ok = true, username = username, role = role }),
        headers = {
            ['Content-Type'] = 'application/json; charset=utf-8',
            ['Cache-Control'] = 'no-store',
            ['Set-Cookie'] = session_cookie(session, SESSION_MAX_AGE),
        },
    }
end)

-- ---------------------------------------------------------------------------
-- Issue a scoped access token (admin only). Mints an HS256 JWT carrying a
-- `role` claim ('admin'|'viewer') and an expiry. The holder can use it as
-- `Authorization: Bearer <token>` on the API, or paste it into the JWT login
-- box to get a session of that role. Minting needs the signing secret, so the
-- caller must be an admin AND XADMIN_JWT_HS256_SECRET must be set.
-- ---------------------------------------------------------------------------
local TOKEN_TTL_MAX = 30 * 24 * 3600
router.reg('post', '/api/tokens', function(req)
    if not require_admin(req) then
        return json(403, { ok = false, error = 'admin role required' })
    end
    local secret, serr = auth.get_jwt_secret()
    if not secret then
        return json(409, { ok = false, error = serr or 'JWT disabled: set XADMIN_JWT_HS256_SECRET' })
    end
    local body = xutils.json_unpack(req.body or '')
    if type(body) ~= 'table' then
        return json(400, { ok = false, error = 'invalid json body' })
    end
    local role = (tostring(body.role or '') == 'admin') and 'admin' or 'viewer'
    local ttl = math.floor(tonumber(body.ttl_seconds) or 3600)
    if ttl < 60 then ttl = 60 end
    if ttl > TOKEN_TTL_MAX then ttl = TOKEN_TTL_MAX end
    local sub = tostring(body.sub or ''):gsub('^%s*(.-)%s*$', '%1')
    if sub == '' then sub = 'token-' .. auth.random_hex(4) end
    if not sub:match('^[%w_%.@%-]+$') or #sub > 64 then
        return json(400, { ok = false, error = 'sub must match [A-Za-z0-9_.@-], <=64 chars' })
    end

    local now = os.time()
    local claims = {
        sub = sub, role = role, iat = now, exp = now + ttl,
        aud = (function()
            local a = xutils.get_config('XADMIN_JWT_AUDIENCE', 'xadmin')
            return (a and a ~= '' and a ~= '*') and a or 'xadmin'
        end)(),
    }
    local iss = xutils.get_config('XADMIN_JWT_ISSUER', nil)
    if iss and iss ~= '' and iss ~= '*' then claims.iss = iss end

    local jwt = auth.jwt_sign_hs256(secret, claims)
    if not jwt then return json(500, { ok = false, error = 'sign failed' }) end
    return json(200, {
        ok = true, token = jwt, sub = sub, role = role,
        exp = claims.exp, expires_in = ttl, issued_by = req.xadmin_user,
    })
end)

-- ---------------------------------------------------------------------------
-- Pure local queries (no yielding RPC)
-- ---------------------------------------------------------------------------
router.reg('get', '/api/peers', function()
    return json(200, {
        self = ctx.self_name or '',
        peers = ctx.alive_peers and ctx.alive_peers() or {},
        token_required = ctx.token_required and true or false,
    })
end)

router.reg('get', '/api/stats', function()
    local threads = xthread.all_stats and xthread.all_stats() or {}
    if type(threads) ~= 'table' then threads = {} end

    local summary = {
        thread_count          = #threads,
        queue_depth_total     = 0,
        queue_max_total       = 0,
        peak_queue_depth      = 0,
        peak_queue_thread_id  = 0,
        peak_queue_thread_name = '',
    }
    for _, st in ipairs(threads) do
        local qd = tonumber(st.queue_depth) or 0
        local qm = tonumber(st.queue_max) or 0
        summary.queue_depth_total = summary.queue_depth_total + qd
        summary.queue_max_total = summary.queue_max_total + qm
        if qd > summary.peak_queue_depth then
            summary.peak_queue_depth = qd
            summary.peak_queue_thread_id = tonumber(st.id) or 0
            summary.peak_queue_thread_name = tostring(st.name or '')
        end
    end

    return json(200, {
        self = ctx.self_name or '',
        at_ms = ctx.now_ms and ctx.now_ms() or math.floor(os.time() * 1000),
        peers = ctx.alive_peers and ctx.alive_peers() or {},
        threads = threads,
        summary = summary,
        token_required = ctx.token_required and true or false,
    })
end)

-- ---------------------------------------------------------------------------
-- Cross-process operations (yields inside xnats.rpc)
-- ---------------------------------------------------------------------------
router.reg('post', '/api/exec', function(req)
    -- /api/exec runs arbitrary Lua on the target process -- admin only. A
    -- viewer (any auto-provisioned SSO user or unlisted mTLS cert holder) is
    -- authenticated but must not reach this.
    if not require_admin(req) then
        return json(403, { ok = false, error = 'admin role required' })
    end
    if not check_token(req) then
        return json(401, { ok = false, error = 'invalid or missing X-Xadmin-Token' })
    end
    local body, perr = xutils.json_unpack(req.body or '')
    if not body or type(body) ~= 'table' then
        return json(400, { ok = false, error = 'invalid json: ' .. tostring(perr or 'expected object') })
    end
    local script = tostring(body.script or '')
    if script == '' then
        return json(400, { ok = false, error = 'script is empty' })
    end

    local rpc_target, terr, label = resolve_rpc_target(body.target or 'self')
    if not rpc_target then
        return json(400, { ok = false, error = terr or 'target unresolved' })
    end
    label = label or rpc_target

    -- xnats.rpc → (channel_ok, app_ok, stdout, result) on success;
    --             (false, channel_err) on channel failure.
    local rets = pack_values(xnats.rpc(rpc_target, '@run_script', script))
    local channel_ok = rets[1] and true or false
    if not channel_ok then
        return json(502, {
            ok = false, target = label,
            stdout = '',
            error = 'rpc failed: ' .. tostring(rets[2]),
        })
    end

    local app_ok = rets[2] and true or false
    return json(app_ok and 200 or 500, {
        ok       = app_ok,
        target   = label,
        stdout   = tostring(rets[3] or ''),
        result   = tostring(rets[4] or ''),
    })
end)

router.reg('post', '/api/reload', function(req)
    if not require_admin(req) then
        return json(403, { ok = false, error = 'admin role required' })
    end
    if not check_token(req) then
        return json(401, { ok = false, error = 'invalid or missing X-Xadmin-Token' })
    end
    local body, perr = xutils.json_unpack(req.body or '')
    if not body or type(body) ~= 'table' then
        return json(400, { ok = false, error = 'invalid json: ' .. tostring(perr or 'expected object') })
    end
    local target = tostring(body.target or 'all')
    if target == '' then target = 'all' end

    -- Build the list of process-name targets.
    local names = {}
    local seen = {}
    local label = target
    if target == 'all' then
        if ctx.self_name and ctx.self_name ~= '' then
            names[#names + 1] = ctx.self_name; seen[ctx.self_name] = true
        end
        for _, p in ipairs(ctx.alive_peers and ctx.alive_peers() or {}) do
            local nm = tostring(p.name or '')
            if nm ~= '' and not seen[nm] then
                names[#names + 1] = nm; seen[nm] = true
            end
        end
    elseif target == 'self' then
        names[1] = ctx.self_name or ''
        label = ctx.self_name or ''
    else
        names[1] = target
    end

    if #names == 0 or names[1] == '' then
        return json(500, {
            ok = false, target = label,
            results = { { target = label, ok = false, result = 'no reload target available' } },
        })
    end

    local self_id = xthread.current_id and xthread.current_id() or 0
    local results = {}
    local all_ok = true

    for _, name in ipairs(names) do
        local rpc_target = name:match(':%d+$') and name or (name .. ':1')
        local rets
        if name == ctx.self_name then
            rets = pack_values(xnats.rpc(rpc_target, '@reload', self_id))
        else
            rets = pack_values(xnats.rpc(rpc_target, '@reload'))
        end

        local channel_ok = rets[1] and true or false
        local ok, msg
        if not channel_ok then
            ok, msg = false, 'rpc error: ' .. tostring(rets[2])
        else
            ok = rets[2] and true or false
            msg = tostring(rets[3] or '')
        end
        if not ok then all_ok = false end
        results[#results + 1] = { target = name, ok = ok, result = msg }
    end

    return json(all_ok and 200 or 500, {
        ok = all_ok, target = label, results = results,
    })
end)

-- Public endpoints that bypass the session gate. Stored as exact paths plus
-- prefixes (anything ending in '/' is a prefix match); checked in M.handle
-- below. OAuth2 /start and /callback are reachable for any provider name.
local PUBLIC_API_EXACT = {
    ['/api/session']    = true,
    ['/api/setup']      = true,
    ['/api/login']      = true,
    ['/api/logout']     = true,
    ['/api/auth/jwt']   = true,
}
local PUBLIC_API_PREFIX = {
    ['/api/auth/oauth/'] = true,
}

local function is_public_api(path)
    if PUBLIC_API_EXACT[path] then return true end
    for prefix, _ in pairs(PUBLIC_API_PREFIX) do
        if path:sub(1, #prefix) == prefix then return true end
    end
    return false
end

function M.handle(req)
    local path = tostring(req.path or '')

    -- Static assets and the SPA shell are always served; the front-end decides
    -- which view (setup / login / console) to show from /api/session.
    if not path:find('^/api/') or is_public_api(path) then
        return router.handle(req)
    end

    -- DEV-ONLY: XADMIN_DEV_NO_AUTH disables all auth/authz for local testing.
    -- Every /api/ request runs as an admin with no login, token, or role check.
    if DEV_NO_AUTH then
        req.xadmin_user = 'dev'
        req.xadmin_role = 'admin'
        return router.handle(req)
    end

    -- The master bypass token grants unconditional access, even before the
    -- console has been configured (DB-backed endpoints will still fail if the
    -- database is unreachable, but auth never blocks).
    if is_super(req) then
        req.xadmin_user = 'super'
        req.xadmin_role = 'admin'
        return router.handle(req)
    end

    -- Everything else under /api/ requires the console to be configured and the
    -- caller to be authenticated (session cookie or X-Xadmin-Token).
    local cfg = store.load_db_config()
    if not cfg.configured then
        return json(403, { ok = false, error = 'console not configured', need = 'setup' })
    end
    local user, role = current_user(req, cfg)
    if not user then
        return json(401, { ok = false, error = 'login required', need = 'login' })
    end
    req.xadmin_user = user
    req.xadmin_role = role
    return router.handle(req)
end

return M
