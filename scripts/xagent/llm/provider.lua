-- xagent/llm/provider.lua — pick the wire-protocol codec for a profile.
--
-- cfg.api_format selects it: 'anthropic' (default, Messages API) or 'openai'
-- (Chat Completions). Both codecs report the same Anthropic-shaped result, so
-- callers (loop, compaction) stay protocol-agnostic.

local M = {}

local CODECS = {
    anthropic = 'xagent.llm.anthropic',
    openai = 'xagent.llm.openai',
    responses = 'xagent.llm.responses',
}

M.FORMATS = { 'anthropic', 'openai', 'responses' }

function M.codec(cfg)
    local fmt = (cfg and cfg.api_format) or 'anthropic'
    local mod = CODECS[fmt]
    if not mod then error('unknown api_format: ' .. tostring(fmt)) end
    return require(mod)
end

-- stream_message(cfg, params, cb) — dispatches to the profile's codec.
function M.stream_message(cfg, params, cb)
    local ok, codec = pcall(M.codec, cfg)
    if not ok then
        if cb and cb.on_error then cb.on_error(tostring(codec)) end
        return
    end
    if cfg.auth_type == 'chatgpt' then
        local co = coroutine.create(function()
            local success, err = pcall(function()
                local credentials = require('xagent.auth.chatgpt').ensure(cfg.proxy)
                local request_cfg = {}; for k, v in pairs(cfg) do request_cfg[k] = v end
                request_cfg.api_key = credentials.access_token
                request_cfg.account_id = credentials.account_id
                require('xagent.llm.responses').stream_message(request_cfg, params, cb)
            end)
            if not success and cb and cb.on_error then cb.on_error(tostring(err)) end
        end)
        local started, err = coroutine.resume(co)
        if not started and cb and cb.on_error then cb.on_error(tostring(err)) end
        return
    end
    return codec.stream_message(cfg, params, cb)
end

return M
