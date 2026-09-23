-- xagent/llm/provider.lua — pick the wire-protocol codec for a profile.
--
-- cfg.api_format selects it: 'anthropic' (default, Messages API) or 'openai'
-- (Chat Completions). Both codecs report the same Anthropic-shaped result, so
-- callers (loop, compaction) stay protocol-agnostic.

local M = {}

local CODECS = {
    anthropic = 'xagent.llm.anthropic',
    openai = 'xagent.llm.openai',
}

M.FORMATS = { 'anthropic', 'openai' }

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
    return codec.stream_message(cfg, params, cb)
end

return M
