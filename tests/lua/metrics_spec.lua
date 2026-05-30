-- Stage 7 spec: per-lane monitoring aggregator (design §16).
--
-- metrics.lua reduces a lane's hot-path pokes into the once-a-second snapshot the
-- lane would xnats.publish to the monitoring topic: windowed counters -> totals +
-- per-second rates, last-write-wins gauges, and frame_ms P50/P95/P99 with the
-- frame_ms.p95 > 12ms overload alert.
--
-- Run via: bin/xnet tests/lua/metrics_spec.lua

local spec = dofile('tests/lua/spec_helper.lua')
local metrics = dofile('scripts/game/metrics.lua')

spec.describe('windowed counters become totals and per-second rates (§16)', function()
    spec.it('a 1s window reports the raw total and an equal rate', function()
        local m = metrics.new({ lane = 3, window_ms = 1000, now_ms = 0 })
        m:inc('combat_ops', 30)
        m:inc('tcp_bytes_out', 4096)
        m:inc('combat_ops')                  -- default by = 1
        local snap = m:snapshot(1000)
        spec.equal(snap.lane, 3)
        spec.equal(snap.window_ms, 1000)
        spec.equal(snap.counters.combat_ops, 31)
        spec.equal(snap.rates.combat_ops, 31, 'over 1s the rate equals the total')
        spec.equal(snap.rates.tcp_bytes_out, 4096)
    end)

    spec.it('combat_ops_per_sec scales by the actual window length', function()
        local m = metrics.new({ now_ms = 0 })
        m:inc('combat_ops', 30)
        local snap = m:snapshot(500)         -- half a second elapsed
        spec.equal(snap.window_ms, 500)
        spec.equal(snap.rates.combat_ops, 60, '30 ops in 0.5s -> 60/s')
    end)

    spec.it('resets windowed counters between snapshots', function()
        local m = metrics.new({ now_ms = 0 })
        m:inc('handoff_count', 5)
        local s1 = m:snapshot(1000)
        spec.equal(s1.counters.handoff_count, 5)
        local s2 = m:snapshot(2000)          -- nothing happened this window
        spec.nil_value(s2.counters.handoff_count, 'counter cleared after publish')
        spec.nil_value(s2.rates.handoff_count)
    end)
end)

spec.describe('gauges are point-in-time and persist across windows (§16)', function()
    spec.it('keeps the last value until overwritten', function()
        local m = metrics.new({ now_ms = 0 })
        m:set('player_count', 42)
        local s1 = m:snapshot(1000)
        spec.equal(s1.gauges.player_count, 42)
        local s2 = m:snapshot(2000)          -- no new set this window
        spec.equal(s2.gauges.player_count, 42, 'gauge survives the window reset')
    end)

    spec.it('snapshots a copy, so later writes do not mutate it', function()
        local m = metrics.new({ now_ms = 0 })
        m:set('q_len', 3)
        local s1 = m:snapshot(1000)
        m:set('q_len', 99)                   -- a later window's value
        spec.equal(s1.gauges.q_len, 3, 'the published snapshot is immutable')
    end)
end)

spec.describe('frame_ms percentiles (nearest-rank) (§16)', function()
    spec.it('reduces samples to P50/P95/P99 regardless of insert order', function()
        local m = metrics.new({ now_ms = 0 })
        for _, ms in ipairs({ 7, 2, 9, 4, 1, 10, 3, 8, 5, 6 }) do  -- 1..10 shuffled
            m:record_frame(ms)
        end
        local snap = m:snapshot(1000)
        spec.equal(snap.frame_ms.count, 10)
        spec.equal(snap.frame_ms.p50, 5, 'rank ceil(.5*10)=5 -> 5')
        spec.equal(snap.frame_ms.p95, 10, 'rank ceil(.95*10)=10 -> 10')
        spec.equal(snap.frame_ms.p99, 10)
    end)

    spec.it('an empty window has zeroed percentiles and no alert', function()
        local m = metrics.new({ now_ms = 0 })
        local snap, alert = m:snapshot(1000)
        spec.equal(snap.frame_ms.p50, 0)
        spec.equal(snap.frame_ms.p95, 0)
        spec.equal(snap.frame_ms.count, 0)
        spec.truthy(not alert, 'no frames -> no overload alert')
    end)
end)

spec.describe('overload alert fires on frame_ms.p95 > 12ms (§16)', function()
    spec.it('flags a lane whose 95th percentile blows the budget', function()
        local m = metrics.new({ now_ms = 0 })
        for _ = 1, 9 do m:record_frame(5) end
        m:record_frame(20)                   -- p95 rank=10 -> 20ms
        local snap, alert = m:snapshot(1000)
        spec.equal(snap.frame_ms.p95, 20)
        spec.truthy(alert, 'p95 20ms > 12ms budget -> overload')
    end)

    spec.it('stays quiet while p95 is within budget', function()
        local m = metrics.new({ now_ms = 0 })
        for _ = 1, 10 do m:record_frame(10) end
        local snap, alert = m:snapshot(1000)
        spec.equal(snap.frame_ms.p95, 10)
        spec.truthy(not alert, 'p95 10ms <= 12ms -> healthy')
    end)
end)

local failures = spec.finish()

return {
    __init = function()
        if failures > 0 then
            os.exit(1)
        end
        xthread.stop(0)
    end,
}
