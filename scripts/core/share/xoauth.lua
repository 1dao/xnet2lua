-- xoauth.lua - stateless OAuth2 / OIDC protocol helpers.
--
-- The caller owns configuration, HTTP transport, browser/callback handling and
-- credential persistence. HTTP functions use the repository convention:
--   http_call(opts) -> err, { status, headers, body }

local xutils = require('xutils')

local M = {}

local function ct_equal(a, b)
    a, b = tostring(a or ''), tostring(b or '')
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = diff | (a:byte(i) ~ b:byte(i))
    end
    return diff == 0
end

function M.b64url_encode(value)
    return xutils.base64url_encode(tostring(value or ''))
end

function M.b64url_decode(value)
    return xutils.base64url_decode(tostring(value or ''))
end

function M.random_bytes(n, source)
    n = tonumber(n) or 0
    if n <= 0 then return '' end
    if source then
        local value = source(n)
        if type(value) ~= 'string' or #value ~= n then
            return nil, 'random source returned the wrong number of bytes'
        end
        return value
    end
    if type(xnet) == 'table' and type(xnet.random_bytes) == 'function' then
        local value = xnet.random_bytes(n)
        if type(value) == 'string' and #value == n then return value end
    end
    local file = io.open('/dev/urandom', 'rb')
    if file then
        local value = file:read(n)
        file:close()
        if type(value) == 'string' and #value == n then return value end
    end
    return nil, 'no cryptographically secure random source available'
end

function M.random_urlsafe(n, source)
    n = tonumber(n) or 32
    if n <= 0 then return '' end
    local raw, err = M.random_bytes(math.ceil(n * 3 / 4), source)
    if not raw then return nil, err end
    return M.b64url_encode(raw):sub(1, n)
end

function M.pkce_pair(source)
    local verifier, err = M.random_urlsafe(64, source)
    if not verifier then return nil, nil, err end
    return verifier, M.b64url_encode(xutils.sha256(verifier))
end

function M.sign_state(secret, claims)
    if not secret or secret == '' then return nil, 'no state secret' end
    local payload = xutils.json_pack(claims or {})
    if not payload then return nil, 'json pack failed' end
    local encoded = M.b64url_encode(payload)
    local signature = M.b64url_encode(xutils.hmac_sha256(secret, encoded))
    return encoded .. '.' .. signature
end

function M.verify_state(secret, token, now)
    if not secret or secret == '' then return nil, 'no state secret' end
    local encoded, signature = tostring(token or ''):match('^(.+)%.(.+)$')
    if not encoded then return nil, 'malformed' end
    local expected = M.b64url_encode(xutils.hmac_sha256(secret, encoded))
    if not ct_equal(signature, expected) then return nil, 'bad signature' end
    local payload = M.b64url_decode(encoded)
    if not payload then return nil, 'bad encoding' end
    local ok, claims = pcall(xutils.json_unpack, payload)
    if not ok or type(claims) ~= 'table' then return nil, 'bad json' end
    if (tonumber(now) or os.time()) > (tonumber(claims.exp) or 0) then
        return nil, 'expired'
    end
    return claims
end

function M.url_encode(value)
    local input = tostring(value or '')
    local out = {}
    for i = 1, #input do
        local byte = input:byte(i)
        if (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122)
            or (byte >= 48 and byte <= 57) or byte == 45 or byte == 95
            or byte == 46 or byte == 126 then
            out[#out + 1] = input:sub(i, i)
        else
            out[#out + 1] = string.format('%%%02X', byte)
        end
    end
    return table.concat(out)
end

function M.url_encode_query(values)
    local out = {}
    for key, value in pairs(values or {}) do
        if value ~= nil then
            out[#out + 1] = M.url_encode(key) .. '=' .. M.url_encode(value)
        end
    end
    return table.concat(out, '&')
end

function M.form_encode(values)
    return M.url_encode_query(values)
end

function M.build_authorize_url(provider, request)
    provider, request = provider or {}, request or {}
    if not provider.auth_url or provider.auth_url == '' then
        return nil, 'missing authorization endpoint'
    end
    if not provider.client_id or provider.client_id == '' then
        return nil, 'missing client_id'
    end
    local params = {}
    for key, value in pairs(provider.authorize_params or {}) do params[key] = value end
    for key, value in pairs(request.extra_params or {}) do params[key] = value end
    params.response_type = 'code'
    params.client_id = provider.client_id
    params.redirect_uri = request.redirect_uri or provider.redirect_uri
    params.scope = request.scope or provider.scope
    params.state = request.state
    if request.code_challenge then
        params.code_challenge = request.code_challenge
        params.code_challenge_method = request.code_challenge_method or 'S256'
    end
    local joiner = provider.auth_url:find('?', 1, true) and '&' or '?'
    return provider.auth_url .. joiner .. M.url_encode_query(params)
end

function M.discover_oidc(provider, http_call)
    if type(provider) ~= 'table' then return nil, 'provider must be a table' end
    if provider.auth_url and provider.token_url then return provider end
    if not provider.issuer or provider.issuer == '' then
        return nil, 'provider needs endpoints or issuer'
    end
    if type(http_call) ~= 'function' then return nil, 'http_call is required' end
    local url = provider.issuer:gsub('/+$', '') .. '/.well-known/openid-configuration'
    local ok, err, response = pcall(http_call, {
        method = 'GET', url = url, timeout_ms = 5000, decompress = true,
    })
    if not ok then return nil, 'oidc discovery: ' .. tostring(err) end
    if err then return nil, 'oidc discovery: ' .. tostring(err) end
    if not response or response.status ~= 200 then
        return nil, 'oidc discovery http ' .. tostring(response and response.status)
    end
    local parsed_ok, document = pcall(xutils.json_unpack, response.body or '')
    if not parsed_ok or type(document) ~= 'table' then
        return nil, 'oidc discovery: bad json'
    end
    provider.auth_url = provider.auth_url or document.authorization_endpoint
    provider.token_url = provider.token_url or document.token_endpoint
    provider.userinfo_url = provider.userinfo_url or document.userinfo_endpoint
    provider.revoke_url = provider.revoke_url or document.revocation_endpoint
    provider.issuer = provider.issuer or document.issuer
    if not provider.auth_url or not provider.token_url then
        return nil, 'oidc discovery: missing endpoints'
    end
    return provider
end

local function token_error(kind, message, response, parsed)
    return {
        kind = kind,
        message = message,
        status = response and response.status or nil,
        body = response and response.body or nil,
        oauth_error = parsed and parsed.error or nil,
        error_description = parsed and parsed.error_description or nil,
    }
end

local function encode_client_request(provider, values)
    local payload = {}
    for key, value in pairs(values or {}) do
        if value ~= nil then payload[key] = value end
    end
    local headers = { Accept = 'application/json' }
    local client_auth = provider.client_auth
        or (provider.client_secret and 'body' or 'none')
    if client_auth == 'none' then
        payload.client_id = provider.client_id
    elseif client_auth == 'body' then
        payload.client_id = provider.client_id
        payload.client_secret = provider.client_secret
    elseif client_auth == 'basic' then
        if not provider.client_id or not provider.client_secret then
            return nil, nil,
                token_error('configuration', 'basic client auth needs id and secret')
        end
        headers.Authorization = 'Basic '
            .. xutils.base64_encode(provider.client_id .. ':' .. provider.client_secret)
    else
        return nil, nil,
            token_error('configuration', 'unsupported client_auth: ' .. tostring(client_auth))
    end

    local encoding = provider.token_encoding or 'form'
    local body
    if encoding == 'json' then
        headers['Content-Type'] = 'application/json'
        body = xutils.json_pack(payload)
    elseif encoding == 'form' then
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
        body = M.form_encode(payload)
    else
        return nil, nil,
            token_error('configuration', 'unsupported token_encoding: ' .. tostring(encoding))
    end
    if not body then
        return nil, nil, token_error('configuration', 'could not encode OAuth request')
    end
    return headers, body
end

local function token_request(provider, values, http_call)
    if type(http_call) ~= 'function' then
        return nil, token_error('configuration', 'http_call is required')
    end
    if not provider.token_url or provider.token_url == '' then
        return nil, token_error('configuration', 'missing token endpoint')
    end
    local headers, body, encode_err = encode_client_request(provider, values)
    if not headers then return nil, encode_err end

    local ok, err, response = pcall(http_call, {
        method = 'POST', url = provider.token_url, headers = headers, body = body,
        timeout_ms = provider.token_timeout_ms or 8000,
    })
    if not ok then return nil, token_error('transport', tostring(err)) end
    if err then return nil, token_error('transport', tostring(err)) end
    if not response then return nil, token_error('transport', 'empty response') end

    local parsed_ok, parsed = pcall(xutils.json_unpack, response.body or '')
    if response.status < 200 or response.status >= 300 then
        if parsed_ok and type(parsed) == 'table' and parsed.error then
            return nil, token_error('oauth', parsed.error_description or parsed.error,
                response, parsed)
        end
        return nil, token_error('http', 'token endpoint HTTP ' .. tostring(response.status), response)
    end
    if not parsed_ok or type(parsed) ~= 'table' then
        return nil, token_error('protocol', 'token endpoint returned invalid JSON', response)
    end
    if not parsed.access_token then
        return nil, token_error('protocol', 'token response missing access_token', response, parsed)
    end
    return parsed
end

function M.exchange_code(provider, request, http_call)
    request = request or {}
    local values = {
        grant_type = 'authorization_code',
        code = request.code,
        redirect_uri = request.redirect_uri or provider.redirect_uri,
        code_verifier = request.code_verifier,
        state = request.state,
    }
    for key, value in pairs(request.extra_params or {}) do values[key] = value end
    return token_request(provider or {}, values, http_call)
end

function M.refresh_token(provider, request, http_call)
    request = request or {}
    local values = {
        grant_type = 'refresh_token',
        refresh_token = request.refresh_token,
        scope = request.scope,
    }
    for key, value in pairs(request.extra_params or {}) do values[key] = value end
    return token_request(provider or {}, values, http_call)
end

function M.revoke_token(provider, request, http_call)
    provider, request = provider or {}, request or {}
    if type(http_call) ~= 'function' then
        return nil, token_error('configuration', 'http_call is required')
    end
    if not provider.revoke_url or provider.revoke_url == '' then
        return nil, token_error('configuration', 'missing revocation endpoint')
    end
    local headers, body, encode_err = encode_client_request(provider, {
        token = request.token,
        token_type_hint = request.token_type_hint,
    })
    if not headers then return nil, encode_err end
    local ok, err, response = pcall(http_call, {
        method = 'POST', url = provider.revoke_url, headers = headers, body = body,
        timeout_ms = provider.token_timeout_ms or 8000,
    })
    if not ok then return nil, token_error('transport', tostring(err)) end
    if err then return nil, token_error('transport', tostring(err)) end
    if not response then return nil, token_error('transport', 'empty response') end
    if response.status < 200 or response.status >= 300 then
        local parsed_ok, parsed = pcall(xutils.json_unpack, response.body or '')
        if parsed_ok and type(parsed) == 'table' and parsed.error then
            return nil, token_error('oauth', parsed.error_description or parsed.error,
                response, parsed)
        end
        return nil, token_error('http',
            'revocation endpoint HTTP ' .. tostring(response.status), response)
    end
    return true
end

return M
