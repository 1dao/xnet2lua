-- scripts/game/metrics.lua -- per-lane monitoring aggregator (design §16).
--
-- Pure logic, no transport. Each lane (gate worker or game battle worker) owns
-- one instance, pokes it on the hot path (inc / add / record_frame) and sets
-- point-in-time gauges, then once a second snapshots it -- the snapshot is the
-- table the lane xnats.publish()es to the monitoring topic. snapshot() also
-- returns the "lane 过载" alert flag (frame_ms.p95 > 12ms, §16) and resets the
-- windowed accumulators so the next second starts clean.
--
-- Two kinds of metric, matching the §16 table:
--   * windowed counters -- summed over the second, reported as a raw total AND a
--     per-second rate, then reset (tcp_bytes_in/out, combat_ops, handoff_count...)
--   * gauges -- last-write-wins point-in-time values that persist across windows
--     (q_len, player_count, gc_lua_kb, peer.rtt_ms...)
-- plus frame_ms samples, reduced to P50/P95/P99 each window.

local M = {}
M.__index = M

local ALERT_FRAME_P95_MS = 12   -- §16: frame_ms.p95 > 12ms => lane overload alert

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, M)
    self.lane = opts.lane
    self.window_ms = opts.window_ms or 1000
    self.alert_p95_ms = opts.alert_p95_ms or ALERT_FRAME_P95_MS
    self.counters = {}      -- windowed; reset every snapshot
    self.gauges = {}        -- persist across snapshots
    self.frames = {}        -- frame_ms samples this window
    self.window_start = opts.now_ms or 0
    return self
end

-- Windowed counter (design §16 rates). `by` defaults to 1.
function M:inc(name, by)
    self.counters[name] = (self.counters[name] or 0) + (by or 1)
end

-- Point-in-time gauge (design §16 levels). Persists until overwritten.
function M:set(name, value)
    self.gauges[name] = value
end

-- One main-loop frame's duration, in ms (design §16 frame_ms).
function M:record_frame(ms)
    self.frames[#self.frames + 1] = ms
end

-- Nearest-rank percentile over an already-sorted sample list. p in [0,100].
local function percentile(sorted, p)
    local n = #sorted
    if n == 0 then return 0 end
    local rank = math.ceil(p / 100 * n)
    if rank < 1 then rank = 1 end
    if rank > n then rank = n end
    return sorted[rank]
end

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- Close the window: build the publishable metric table + the overload alert,
-- then reset windowed state (counters + frame samples). Gauges are point-in-time
-- so they carry over. now_ms drives the rate denominator and the next window
-- start; when it doesn't advance past window_start we fall back to window_ms so
-- rates never divide by zero.
function M:snapshot(now_ms)
    now_ms = now_ms or 0
    local elapsed = now_ms - self.window_start
    local secs = (elapsed > 0 and elapsed or self.window_ms) / 1000

    local sorted = {}
    for i = 1, #self.frames do sorted[i] = self.frames[i] end
    table.sort(sorted)
    local p50 = percentile(sorted, 50)
    local p95 = percentile(sorted, 95)
    local p99 = percentile(sorted, 99)

    local rates = {}
    for name, v in pairs(self.counters) do
        rates[name] = v / secs
    end

    local snap = {
        lane = self.lane,
        window_ms = elapsed,
        frame_ms = { p50 = p50, p95 = p95, p99 = p99, count = #self.frames },
        counters = self.counters,    -- raw totals over the window
        rates = rates,               -- per-second
        gauges = copy(self.gauges),  -- snapshot of current levels
    }
    local alert = p95 > self.alert_p95_ms

    self.counters = {}
    self.frames = {}
    self.window_start = now_ms
    return snap, alert
end

return M
