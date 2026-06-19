-- Regression specs for xadmin's compatibility adapter over shared xoauth.

local spec   = dofile('tests/lua/spec_helper.lua')
local auth   = dofile('scripts/xadmin/xadmin_auth.lua')

spec.describe('xadmin OAuth compatibility adapter', function()
    spec.it('preserves existing PKCE and signed-state helpers', function()
        local verifier, challenge = auth.pkce_pair()
        spec.equal(#verifier, 64)
        spec.truthy(type(challenge) == 'string' and challenge ~= '')

        local state = assert(auth.sign_state('secret', { p = 'github', exp = os.time() + 60 }))
        local claims = assert(auth.verify_state('secret', state))
        spec.equal(claims.p, 'github')
    end)

    spec.it('delegates authorization URL construction to shared OAuth', function()
        local url = assert(auth.build_authorize_url({
            auth_url = 'https://id.example/auth',
            client_id = 'xadmin',
            scope = 'openid email',
        }, {
            redirect_uri = 'https://admin.example/api/auth/oauth/id/callback',
            state = 'signed-state',
            code_challenge = 'challenge',
        }))
        spec.contains(url, 'client_id=xadmin')
        spec.contains(url, 'scope=openid%20email')
        spec.contains(url, 'state=signed-state')
        spec.contains(url, 'code_challenge=challenge')
    end)

    spec.it('keeps xadmin form/body token exchange defaults', function()
        local seen
        local token = assert(auth.exchange_code({
            token_url = 'https://id.example/token',
            client_id = 'xadmin',
            client_secret = 'secret',
        }, {
            code = 'code', redirect_uri = 'https://admin.example/callback',
            code_verifier = 'verifier',
        }, function(opts)
            seen = opts
            return nil, { status = 200, body = '{"access_token":"token"}' }
        end))
        spec.equal(token.access_token, 'token')
        spec.equal(seen.headers['Content-Type'], 'application/x-www-form-urlencoded')
        spec.contains(seen.body, 'client_id=xadmin')
        spec.contains(seen.body, 'client_secret=secret')
    end)

    spec.it('preserves JWT HS256 behavior', function()
        local token = assert(auth.jwt_sign_hs256('jwt-secret', {
            sub = 'user', exp = os.time() + 60,
        }))
        local claims = assert(auth.jwt_verify_hs256('jwt-secret', token))
        spec.equal(claims.sub, 'user')
    end)
end)

local failures = spec.finish()
return {
    __init = function()
        if failures > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}
