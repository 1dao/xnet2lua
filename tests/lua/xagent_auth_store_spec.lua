-- Exercise the real desktop permission/storage adapter with synthetic data only.
package.path='scripts/?.lua;'..package.path
local spec=dofile('tests/lua/spec_helper.lua')
local json=require('xutils')
local original=dofile
local root=(os.getenv('TEMP') or '/tmp')..'/codua-auth-test-'..tostring(os.time())
function dofile(path)
    local value=original(path)
    if path=='scripts/core/share/xfs.lua' then value.home=function() return root end end
    return value
end
local store=require('xagent.auth.file_store')
dofile=original
spec.describe('Desktop credential storage',function()
    spec.it('writes, rotates, recovers, and deletes credentials in a private directory',function()
        assert(store.save({access_token='synthetic-a',refresh_token='synthetic-r'}))
        spec.equal(store.load().refresh_token,'synthetic-r')
        assert(store.save({access_token='synthetic-b',refresh_token='synthetic-r2'}))
        spec.equal(store.load().refresh_token,'synthetic-r2')
        local path=root..'/.xagent/auth/chatgpt.json'
        assert(os.rename(path,path..'.previous'))
        spec.equal(store.load().refresh_token,'synthetic-r2')
        assert(store.save(nil));spec.nil_value(store.load())
        os.remove(root..'/.xagent/auth');os.remove(root..'/.xagent');os.remove(root)
    end)
end)
local failed=spec.finish()
return {__init=function() if failed>0 then os.exit(1) end;xthread.stop(0) end}
