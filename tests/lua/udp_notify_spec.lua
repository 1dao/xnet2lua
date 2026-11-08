local spec = dofile('tests/lua/spec_helper.lua')
local notify = dofile('scripts/core/share/xudp_notify.lua')

-- Test-only encoding and IDs, independent of the undecided production format.
local function compare(a, b)
    a, b = tonumber(a), tonumber(b)
    return a < b and -1 or (a > b and 1 or 0)
end

local function sender(overrides)
    local packets, next_id = {}, 0
    local o = {now = 0, max_messages = 4, max_bytes = 100,
        max_message_bytes = 30, max_batch_bytes = 32, heartbeat_ms = 100,
        retry_ms = 10, retry_max_ms = 40, send_retry_ms = 5,
        round_timeout_ms = 200, session_timeout_ms = 500, max_attempts = 12,
        compare_ids = compare, next_id = function() next_id = next_id + 1; return tostring(next_id) end,
        pack = function(_, messages, budget)
            local batch, bytes = {}, 0
            for _, message in ipairs(messages) do
                if bytes + #message + 1 > budget then break end
                batch[#batch + 1], bytes = message, bytes + #message + 1
            end
            return table.concat(batch, '|'), #batch
        end,
        send_ping = function(id, body)
            packets[#packets + 1] = {id, body}
            return true
        end}
    for k, v in pairs(overrides or {}) do o[k] = v end
    return notify.new_sender(o), packets
end

local function receiver(overrides)
    local pongs = {}
    local o = {max_batches = 4, max_messages = 4, max_bytes = 100, max_batch_bytes = 32,
        compare_ids = compare,
        decode = function(_, body)
            if body == 'bad' then return nil end
            local messages = {}
            for message in body:gmatch('[^|]+') do messages[#messages + 1] = message end
            return messages
        end,
        send_pong = function(id) pongs[#pongs + 1] = id; return true end}
    for k, v in pairs(overrides or {}) do o[k] = v end
    return notify.new_receiver(o), pongs
end

spec.describe('single-current UDP notification mechanism', function()
    spec.it('retries immutable content and matches only the current Pong', function()
        local s, packets = sender()
        assert(s:enqueue('A')); assert(s:enqueue('B')); assert(s:step(0))
        assert(s:enqueue('C')); assert(s:step(9))
        spec.equal(#packets, 1)
        assert(s:step(10))
        spec.equal(packets[2][1], '1')
        spec.equal(packets[2][2], 'A|B')
        spec.equal(s:status().next_retry, 30)
        spec.equal(s:status().deadline, 200)
        spec.equal(s:status().last_receive, 0)
        assert(s:ack('1', 11))
        spec.equal(packets[3][1], '2')
        spec.equal(packets[3][2], 'C')
        spec.equal(s:ack('1', 12), false)
        spec.equal(s:status().current_id, '2')
        spec.equal(s:status().last_receive, 11)
        assert(s:ack('2', 13))
        spec.equal(s:status().held_messages, 0)
        spec.equal(s:status().held_bytes, 0)
    end)

    spec.it('reschedules idle heartbeat on actual send, never on queueing or failure', function()
        local s, packets = sender()
        assert(s:step(0)); spec.equal(#packets, 0)
        assert(s:enqueue('A')); assert(s:step(60))
        spec.equal(s:status().next_heartbeat, 160)
        assert(s:enqueue('B'))
        spec.equal(s:status().next_retry, 70)
        spec.equal(s:status().next_heartbeat, 160)
        assert(s:ack('1', 61)) -- queued B goes immediately
        assert(s:ack('2', 62))
        assert(s:step(160)); spec.equal(#packets, 2)
        assert(s:step(161)); spec.equal(packets[3][2], '')
        assert(s:enqueue('C')) -- empty round is immutable
        assert(s:step(171)); spec.equal(packets[4][2], '')
        assert(s:ack('3', 172)); spec.equal(packets[5][2], 'C')
        spec.equal(s:status().next_heartbeat, 272)
        local failed = sender({send_ping = function() return false, 'would_block' end})
        assert(failed:enqueue('X'))
        spec.equal(failed:step(20), false)
        spec.equal(failed:status().next_heartbeat, 100)
        spec.equal(failed:status().next_retry, 25)
        spec.equal(failed:ack('1', 21), false) -- never sent
        assert(failed:step(24))
        spec.equal(failed:status().send_failures, 1)
    end)

    spec.it('keeps data on packing failure and applies in-flight capacity', function()
        local fail = true
        local s = sender({max_messages = 2, pack = function(_, messages)
            if fail then return nil end
            return messages[1], 1
        end})
        assert(s:enqueue('A')); assert(s:enqueue('B'))
        spec.equal(s:enqueue('C'), false)
        spec.equal(s:step(0), false)
        spec.equal(s:status().pending, 2)
        fail = false
        assert(s:step(5))
        spec.equal(s:status().current_id, '2')
        spec.equal(s:status().pending, 1)
        spec.equal(s:enqueue('C'), false) -- A still consumes capacity
        assert(s:ack('2', 6))
        spec.equal(s:status().current_body, 'B')
        assert(s:enqueue('C'))
        spec.equal(s:enqueue(string.rep('x', 31)), false)
    end)

    spec.it('bounds retries and lifetime without extending either on outgoing data', function()
        local s = sender({round_timeout_ms = 25})
        assert(s:enqueue('A')); assert(s:step(0)); assert(s:step(10))
        assert(s:valid_receive(20))
        assert(s:enqueue('B'))
        spec.equal(s:step(25), false)
        spec.equal(s:status().expired, 'round_timeout')
        spec.equal(s:status().held_messages, 2) -- business chooses timeout policy
        spec.equal(s:ack('1', 25), false)
        local limited = sender({max_attempts = 2, send_ping = function() return false end})
        assert(limited:enqueue('A'))
        spec.equal(limited:step(0), false)
        spec.equal(limited:step(5), false)
        spec.equal(limited:step(10), false)
        spec.equal(limited:status().expired, 'attempt_limit')
        local idle = sender({heartbeat_ms = 1000, session_timeout_ms = 30})
        spec.equal(idle:ack('old', 20), false)
        spec.equal(idle:step(30), false)
        spec.equal(idle:status().expired, 'session_timeout')
        spec.equal(pcall(function() idle:step(29) end), false)
    end)

    spec.it('does not deliver duplicates and acknowledges before application execution', function()
        local r, pongs = receiver()
        assert(r:receive('1', 'A|B'))
        spec.equal(#pongs, 1)
        assert(r:receive('1', 'A|B'))
        spec.equal(#pongs, 2)
        spec.equal(r:receive('1', 'different'), false)
        local messages, id = r:take()
        spec.equal(id, '1'); spec.equal(messages[1], 'A'); spec.equal(messages[2], 'B')
        spec.equal(r:take(), nil)
        assert(r:receive('2', 'C'))
        assert(r:receive('1', 'A|B')) -- late old Ping: acknowledge, never apply
        spec.equal(pongs[#pongs], '1')
        messages = r:take(); spec.equal(messages[1], 'C')
        spec.equal(r:take(), nil)
    end)

    spec.it('rejects malformed/full input without Pong and retries after capacity recovers', function()
        local r, pongs = receiver({max_batches = 1})
        spec.equal(r:receive('1', 'bad'), false); spec.equal(#pongs, 0)
        assert(r:receive('1', 'A'))
        spec.equal(r:receive('2', 'B'), false); spec.equal(#pongs, 1)
        r:take()
        assert(r:receive('2', 'B')); spec.equal(#pongs, 2)
        assert(r:receive('2', 'B')); spec.equal(#pongs, 3)
        assert(r:receive('3', '')) -- no business slot required even while full
        r:take()
        assert(r:receive('4', ''))
        spec.equal(r:take(), nil)
        local malformed = receiver({decode = function() return {[2] = 'hole'} end})
        spec.equal(malformed:receive('1', ''), false)
    end)

    spec.it('recovers Ping and Pong loss through logical retry with one delivery', function()
        local s, packets = sender()
        local r, pongs = receiver()
        assert(s:enqueue('A')); assert(s:step(0)) -- drop original Ping
        assert(s:step(10)); assert(r:receive(packets[2][1], packets[2][2])) -- drop Pong
        assert(s:step(30)); assert(r:receive(packets[3][1], packets[3][2]))
        assert(s:ack(pongs[2], 31))
        spec.equal(s:status().held_messages, 0)
        spec.equal(r:take()[1], 'A')
        spec.equal(r:take(), nil)
        spec.equal(s:status().retries, 2)
    end)

    spec.it('sends only whole messages within the pack budget and preserves unsent ownership', function()
        local s, packets = sender()
        local a, b = string.rep('a', 20), string.rep('b', 20)
        assert(s:enqueue(a)); assert(s:enqueue(b)); assert(s:step(0))
        spec.equal(packets[1][2], a)
        spec.equal(s:status().pending, 1)
        assert(s:ack('1', 1))
        spec.equal(packets[2][2], b)
        local invalid = sender({pack = function() return 'invalid', 0 end})
        assert(invalid:enqueue('A'))
        spec.equal(invalid:step(0), false)
        spec.equal(invalid:status().held_bytes, 1)
        spec.equal(invalid:status().pending, 1)
        spec.equal(invalid:status().current_id, nil)
    end)

    spec.it('retries local failure without changing round identity or postponing idle heartbeat', function()
        local attempts = 0
        local s = sender({send_ping = function(id, body)
            spec.equal(id, '1'); spec.equal(body, 'A')
            attempts = attempts + 1
            return attempts > 1
        end})
        assert(s:enqueue('A'))
        spec.equal(s:step(20), false)
        assert(s:step(24)); spec.equal(attempts, 1)
        assert(s:step(25)); spec.equal(attempts, 2)
        spec.equal(s:status().next_heartbeat, 125)
        spec.equal(s:status().deadline, 220)
        assert(s:ack('1', 26))
    end)

    spec.it('retains accepted delivery on Pong failure and rejects reused sender IDs', function()
        local attempts = 0
        local r = receiver({send_pong = function()
            attempts = attempts + 1
            return attempts > 1
        end})
        local accepted, kind, sent = r:receive('1', 'A')
        spec.equal(accepted, true); spec.equal(kind, 'accepted'); spec.equal(sent, false)
        accepted, kind, sent = r:receive('1', 'A')
        spec.equal(accepted, true); spec.equal(kind, 'duplicate'); spec.equal(sent, true)
        spec.equal(r:take()[1], 'A'); spec.equal(r:take(), nil)
        local s = sender({next_id = function() return '1' end})
        assert(s:enqueue('A')); assert(s:step(0)); assert(s:ack('1', 1))
        assert(s:enqueue('B'))
        local ok, reason = s:step(2)
        spec.equal(ok, false); spec.equal(reason, 'non_increasing_ping_id')
        spec.equal(s:status().pending, 1)
    end)
end)

local failures = spec.finish()
return {__init = function() xthread.stop(failures > 0 and 1 or 0) end}
