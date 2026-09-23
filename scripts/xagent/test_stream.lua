-- xagent/test_stream.lua — live end-to-end streaming check against a real
-- Anthropic- or OpenAI-compatible endpoint. Unlike tests/lua/xagent_llm_spec.lua (offline,
-- deterministic), this one actually opens a TLS connection and streams tokens.
--
-- Run (PowerShell):
--   $env:ANTHROPIC_AUTH_TOKEN="sk-..."; .\bin\xnet.exe scripts\xagent\test_stream.lua
-- Optional overrides (env or KEY=VALUE argv):
--   ANTHROPIC_BASE_URL  (default https://api.anthropic.com)
--   ANTHROPIC_MODEL / MODEL=...        (default below)
--   PROMPT="..."        the user message
--   AUTH_STYLE=bearer   for OpenAI-style "Authorization: Bearer" endpoints
--   API_FORMAT=openai   speak Chat Completions instead of Messages
--   BASE_URL=...        endpoint override (e.g. https://api.deepseek.com)
--
-- NOTE: Lua print() is routed to the log file by the runtime; this script uses
-- io.write + io.flush so the streamed text shows on the real stdout.

package.path = 'scripts/?.lua;' .. package.path
local provider = require('xagent.llm.provider')
local config = require('xagent.config')

-- KEY=VALUE argv overrides (the runner exposes them in the global `arg`).
local argv = {}
if type(arg) == 'table' then
    for _, item in ipairs(arg) do
        local k, v = tostring(item):match('^([%w_]+)=(.*)$')
        if k then argv[k] = v end
    end
end

-- Base config from xnet.cfg + xagent.local.cfg + env; argv can override.
local cfg = config.load()
if argv.MODEL then cfg.model = argv.MODEL end
if argv.BASE_URL then cfg.base_url = argv.BASE_URL end
if argv.API_FORMAT then
    cfg.api_format = argv.API_FORMAT
    cfg.auth_style = config.infer_auth_style(cfg.base_url, cfg.api_format)
end
if argv.AUTH_STYLE then cfg.auth_style = argv.AUTH_STYLE end
local base_url = cfg.base_url
local model    = cfg.model
local prompt   = argv.PROMPT or os.getenv('PROMPT')
    or 'In one short sentence, say hello and name yourself.'

local function out(s) io.write(s); io.flush() end

local function __init()
    if not cfg.api_key or cfg.api_key == '' then
        io.stderr:write('ERROR: no token — set XAGENT_AUTH_TOKEN in xagent.local.cfg\n')
        xthread.stop(2)
        return
    end

    assert(xnet.init())
    out(string.format('--- streaming from %s  (model=%s, %s) ---\n',
        base_url, model, tostring(cfg.api_format)))

    provider.stream_message(cfg, {
        messages = { { role = 'user', content = prompt } },
        max_tokens = tonumber(argv.MAX_TOKENS) or 256,
    }, {
        on_text = function(delta) out(delta) end,
        on_tool_use_start = function(id, name)
            out(string.format('\n[tool_use %s %s]\n', name, id))
        end,
        on_done = function(result)
            out('\n--- done ---\n')
            out(string.format('stop_reason=%s  in=%d out=%d  blocks=%d\n',
                tostring(result.stop_reason),
                result.usage.input_tokens or 0,
                result.usage.output_tokens or 0,
                #result.message.content))
            xthread.stop(0)
        end,
        on_error = function(err)
            io.stderr:write('\nSTREAM ERROR: ' .. tostring(err) .. '\n')
            xthread.stop(1)
        end,
    })
end

local function __uninit()
    if xnet and xnet.uninit then xnet.uninit() end
end

return {
    __tick_ms = 10,
    __thread_handle = function() end,
    __init = __init,
    __uninit = __uninit,
}
