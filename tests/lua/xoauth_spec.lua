-- Offline specs for scripts/core/share/xoauth.lua.
-- Run via: bin/xnet.exe tests/lua/xoauth_spec.lua

local spec   = dofile('tests/lua/spec_helper.lua')
local xutils = require('xutils')
local oauth  = dofile('scripts/core/share/xoauth.lua')

spec.describe('xoauth primitives', function()
    spec.it('builds an RFC 7636 S256 PKCE pair', function()
        local verifier, challenge = oauth.pkce_pair(function(n)
            return string.rep('\0', n)
        end)
        spec.equal(#verifier, 64)
        spec.equal(challenge, xutils.base64url_encode(xutils.sha256(verifier)))
        spec.truthy(verifier:match('^[A-Za-z0-9_-]+$'))
    end)

    spec.it('signs, verifies, and expires state', function()
        local token = assert(oauth.sign_state('secret', { p = 'google', exp = 200 }))
        local claims = assert(oauth.verify_state('secret', token, 100))
        spec.equal(claims.p, 'google')

        local bad, bad_err = oauth.verify_state('secret', token .. 'x', 100)
        spec.nil_value(bad)
        spec.equal(bad_err, 'bad signature')

        local expired, expired_err = oauth.verify_state('secret', token, 201)
        spec.nil_value(expired)
        spec.equal(expired_err, 'expired')
    end)

    spec.it('encodes query and form values', function()
        spec.equal(oauth.url_encode('a b+c/'), 'a%20b%2Bc%2F')
        local encoded = oauth.url_encode_query({ a = 'hello world', b = '+' })
        spec.contains(encoded, 'a=hello%20world')
        spec.contains(encoded, 'b=%2B')
        spec.equal(oauth.form_encode({ a = 'x y' }), 'a=x%20y')
    end)
end)

spec.describe('xoauth authorization and discovery', function()
    spec.it('builds an authorization-code URL with PKCE', function()
        local url = assert(oauth.build_authorize_url({
            auth_url = 'https://id.example/authorize',
            client_id = 'client',
            scope = 'openid profile',
        }, {
            redirect_uri = 'http://127.0.0.1/callback',
            state = 'state',
            code_challenge = 'challenge',
        }))
        spec.contains(url, 'https://id.example/authorize?')
        spec.contains(url, 'response_type=code')
        spec.contains(url, 'client_id=client')
        spec.contains(url, 'redirect_uri=http%3A%2F%2F127.0.0.1%2Fcallback')
        spec.contains(url, 'scope=openid%20profile')
        spec.contains(url, 'state=state')
        spec.contains(url, 'code_challenge=challenge')
        spec.contains(url, 'code_challenge_method=S256')
    end)

    spec.it('discovers missing OIDC endpoints through injected HTTP', function()
        local seen
        local provider = { issuer = 'https://id.example/' }
        local out = assert(oauth.discover_oidc(provider, function(opts)
            seen = opts
            return nil, {
                status = 200,
                body = xutils.json_pack({
                    issuer = 'https://id.example',
                    authorization_endpoint = 'https://id.example/auth',
                    token_endpoint = 'https://id.example/token',
                    userinfo_endpoint = 'https://id.example/me',
                    revocation_endpoint = 'https://id.example/revoke',
                }),
            }
        end))
        spec.equal(seen.url, 'https://id.example/.well-known/openid-configuration')
        spec.equal(out.auth_url, 'https://id.example/auth')
        spec.equal(out.token_url, 'https://id.example/token')
        spec.equal(out.userinfo_url, 'https://id.example/me')
        spec.equal(out.revoke_url, 'https://id.example/revoke')
    end)
end)

spec.describe('xoauth token requests', function()
    spec.it('exchanges a code using form body client authentication', function()
        local seen
        local token = assert(oauth.exchange_code({
            token_url = 'https://id.example/token',
            client_id = 'client',
            client_secret = 'secret',
            client_auth = 'body',
            token_encoding = 'form',
        }, {
            code = 'code', redirect_uri = 'http://localhost/cb', code_verifier = 'verifier',
        }, function(opts)
            seen = opts
            return nil, { status = 200, body = '{"access_token":"access","refresh_token":"refresh"}' }
        end))
        spec.equal(token.access_token, 'access')
        spec.equal(seen.headers['Content-Type'], 'application/x-www-form-urlencoded')
        spec.contains(seen.body, 'grant_type=authorization_code')
        spec.contains(seen.body, 'client_id=client')
        spec.contains(seen.body, 'client_secret=secret')
        spec.contains(seen.body, 'code_verifier=verifier')
    end)

    spec.it('exchanges a code as JSON for a public client', function()
        local seen
        local token = assert(oauth.exchange_code({
            token_url = 'https://id.example/token',
            client_id = 'public-client',
            client_auth = 'none',
            token_encoding = 'json',
        }, { code = 'code', redirect_uri = 'http://localhost/cb', code_verifier = 'v' },
        function(opts)
            seen = opts
            return nil, { status = 200, body = '{"access_token":"access"}' }
        end))
        local body = xutils.json_unpack(seen.body)
        spec.equal(token.access_token, 'access')
        spec.equal(seen.headers['Content-Type'], 'application/json')
        spec.equal(body.client_id, 'public-client')
        spec.nil_value(body.client_secret)
    end)

    spec.it('supports HTTP basic client authentication', function()
        local seen
        assert(oauth.refresh_token({
            token_url = 'https://id.example/token',
            client_id = 'client', client_secret = 'secret',
            client_auth = 'basic', token_encoding = 'form',
        }, { refresh_token = 'refresh' }, function(opts)
            seen = opts
            return nil, { status = 200, body = '{"access_token":"next"}' }
        end))
        spec.equal(seen.headers.Authorization,
            'Basic ' .. xutils.base64_encode('client:secret'))
        spec.contains(seen.body, 'grant_type=refresh_token')
        spec.contains(seen.body, 'refresh_token=refresh')
        spec.truthy(not seen.body:find('client_secret=', 1, true))
    end)

    spec.it('revokes a token through the configured endpoint', function()
        local seen
        local ok = assert(oauth.revoke_token({
            revoke_url = 'https://id.example/revoke',
            client_id = 'public-client', client_auth = 'none', token_encoding = 'json',
        }, { token = 'refresh', token_type_hint = 'refresh_token' }, function(opts)
            seen = opts
            return nil, { status = 204, body = '' }
        end))
        spec.truthy(ok)
        local body = xutils.json_unpack(seen.body)
        spec.equal(seen.url, 'https://id.example/revoke')
        spec.equal(body.token, 'refresh')
        spec.equal(body.token_type_hint, 'refresh_token')
        spec.equal(body.client_id, 'public-client')
    end)

    spec.it('returns structured transport, HTTP, and OAuth errors', function()
        local provider = { token_url = 'https://id.example/token', client_id = 'client' }
        local _, transport = oauth.exchange_code(provider, { code = 'x' }, function()
            return 'offline', nil
        end)
        spec.equal(transport.kind, 'transport')

        local _, http = oauth.exchange_code(provider, { code = 'x' }, function()
            return nil, { status = 503, body = 'down' }
        end)
        spec.equal(http.kind, 'http')
        spec.equal(http.status, 503)

        local _, protocol = oauth.exchange_code(provider, { code = 'x' }, function()
            return nil, { status = 400, body = '{"error":"invalid_grant","error_description":"bad code"}' }
        end)
        spec.equal(protocol.kind, 'oauth')
        spec.equal(protocol.oauth_error, 'invalid_grant')
    end)
end)

local failures = spec.finish()
return {
    __init = function()
        if failures > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
