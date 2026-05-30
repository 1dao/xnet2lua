-- scripts/game/chatfilter.lua -- work-worker chat pre-processing (design §10).
--
-- Pure logic, no transport. §10 puts "聊天前处理(敏感词、限流)" on the work worker:
-- a chat line coming off battle is handed here BEFORE it is broadcast, so the
-- spam check and profanity mask run off the 16ms battle frame. Two pieces:
--
--   * rate limit -- a per-sender token bucket: a small burst is fine, sustained
--     spam is throttled. Tokens refill continuously, so a sender who waits gets
--     to talk again without a hard per-window cliff.
--   * sensitive words -- case-insensitive masking, replacing each banned run with
--     the mask char so the message length/shape is preserved.
--
-- process() runs the rate gate first (a throttled line is dropped, never even
-- filtered) and otherwise returns the sanitized text.

local M = {}
M.__index = M

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, M)
    self.burst = opts.burst or 5            -- bucket capacity (max burst)
    self.refill_ms = opts.refill_ms or 1000 -- ms to regenerate one token
    self.mask = opts.mask or '*'
    self.buckets = {}                       -- [sid] = { tokens, last_ms }
    self.banned = {}                        -- list of lowercased words
    for _, w in ipairs(opts.banned or {}) do self:ban(w) end
    return self
end

-- ----- rate limit (token bucket) -----

-- Consume one token for `sid`. Returns true if allowed, false if throttled.
function M:allow(sid, now_ms)
    now_ms = now_ms or 0
    local b = self.buckets[sid]
    if not b then
        b = { tokens = self.burst, last = now_ms }
        self.buckets[sid] = b
    else
        local elapsed = now_ms - b.last
        if elapsed > 0 then
            b.tokens = math.min(self.burst, b.tokens + elapsed / self.refill_ms)
            b.last = now_ms
        end
    end
    if b.tokens >= 1 then
        b.tokens = b.tokens - 1
        return true
    end
    return false
end

-- ----- sensitive words -----

function M:ban(word)
    word = tostring(word or ''):lower()
    if word ~= '' then self.banned[#self.banned + 1] = word end
end

-- Mask every banned run (case-insensitive) with the mask char, preserving length.
-- Returns sanitized_text, changed.
function M:sanitize(text)
    local result = tostring(text or '')
    local changed = false
    for _, w in ipairs(self.banned) do
        local lower_cur = result:lower()
        local out = {}
        local pos = 1
        while true do
            local s, e = lower_cur:find(w, pos, true)
            if not s then break end
            out[#out + 1] = result:sub(pos, s - 1)
            out[#out + 1] = string.rep(self.mask, e - s + 1)
            pos = e + 1
            changed = true
        end
        out[#out + 1] = result:sub(pos)
        result = table.concat(out)
    end
    return result, changed
end

-- ----- combined entry point -----

-- Rate-gate then sanitize a chat line from `sid`. Returns a result table:
--   { ok = false, reason = 'rate_limited' }                 -- dropped
--   { ok = true, text = <masked>, filtered = <bool> }       -- forward this
function M:process(sid, text, now_ms)
    if not self:allow(sid, now_ms) then
        return { ok = false, reason = 'rate_limited' }
    end
    local clean, changed = self:sanitize(text)
    return { ok = true, text = clean, filtered = changed }
end

return M
