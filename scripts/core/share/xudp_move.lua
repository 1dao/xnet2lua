-- Self-contained snapshots, latest pending value per entity. Stop/pause uses
-- the notification channel; accepting it uses the same version comparison.
assert(type(require('xnet').udp_bind) == 'function', 'UDP support is not enabled')
local M, Sender, Receiver = {}, {}, {}
Sender.__index, Receiver.__index = Sender, Receiver
local function valid(n) return type(n) == 'number' and n >= 0 and n <= 2147483647 and n % 1 == 0 end
local function newer(a, b)
    if a.generation ~= b.generation then return a.generation > b.generation end
    if a.motion ~= b.motion then return a.motion > b.motion end
    return a.sequence > b.sequence
end
function M.valid(s)
    return type(s) == 'table' and type(s.entity) == 'string' and #s.entity > 0 and #s.entity <= 64
        and valid(s.generation) and valid(s.motion) and valid(s.sequence) and type(s.payload) == 'string'
end
local function copy(s)
    return {entity = s.entity, generation = s.generation, motion = s.motion,
        sequence = s.sequence, payload = s.payload}
end
function M.new_sender(o)
    assert(type(o.send) == 'function')
    local entities, bytes, payload, budget = o.max_entities or 128, o.max_bytes or 65536,
        o.max_payload_bytes or 512, o.send_budget or 16
    assert(valid(entities) and entities > 0 and valid(bytes) and bytes > 0 and
        valid(payload) and payload > 0 and valid(budget) and budget > 0)
    return setmetatable({send = o.send, max_entities = entities, max_bytes = bytes,
        max_payload = payload, budget = budget, pending = {}, order = {}, bytes = 0,
        versions = {}, entities = 0}, Sender)
end
function Sender:put(state)
    assert(not self.busy, 'MOVE send hook reentry')
    if not M.valid(state) or #state.payload > self.max_payload then return false, 'invalid_move' end
    local id, old = state.entity, self.versions[state.entity]
    if old and not newer(state, old) then return false, 'stale_move' end
    if not old and self.entities >= self.max_entities then return false, 'capacity' end
    local pending = self.pending[id]
    local bytes = self.bytes - (pending and #pending.payload or 0) + #state.payload
    if bytes > self.max_bytes then return false, 'capacity' end
    local owned = copy(state)
    if not pending then self.order[#self.order + 1] = id end
    self.pending[id], self.bytes = owned, bytes
    -- Keep only ordering metadata after a successful send, not old payloads.
    self.versions[id] = {generation = state.generation, motion = state.motion, sequence = state.sequence}
    if not old then self.entities = self.entities + 1 end
    return true
end
function Sender:flush()
    assert(not self.busy, 'MOVE send hook reentry')
    local sent = 0
    local attempts = math.min(#self.order, self.budget)
    for _ = 1, attempts do
        local id = table.remove(self.order, 1)
        local state = self.pending[id]
        self.busy = true
        local ok, accepted = pcall(self.send, copy(state))
        self.busy = false
        if ok and accepted == true then
            self.pending[id], self.bytes = nil, self.bytes - #state.payload
            sent = sent + 1
        else self.order[#self.order + 1] = id end -- round robin on local failure
    end
    return sent
end
function Sender:forget(entity)
    assert(not self.busy, 'MOVE send hook reentry')
    if self.pending[entity] then
        self.bytes = self.bytes - #self.pending[entity].payload
        self.pending[entity] = nil
        for i, id in ipairs(self.order) do if id == entity then table.remove(self.order, i); break end end
    end
    if self.versions[entity] then self.entities = self.entities - 1; self.versions[entity] = nil end
end
function M.new_receiver(o)
    o = o or {}
    local max = o.max_entities or 128
    assert(valid(max) and max > 0)
    return setmetatable({versions = {}, count = 0, max_entities = max}, Receiver)
end
function Receiver:baseline(entity, generation)
    if type(entity) ~= 'string' or #entity == 0 or #entity > 64 or not valid(generation) then
        return false, 'invalid_baseline'
    end
    local old = self.versions[entity]
    if old and generation <= old.generation then return false, 'stale_baseline' end
    if not old and self.count >= self.max_entities then return false, 'capacity' end
    if not old then self.count = self.count + 1 end
    self.versions[entity] = {generation = generation, motion = -1, sequence = -1}
    return true
end
function Receiver:accept(state)
    if not M.valid(state) then return false, 'invalid_move' end
    local old = self.versions[state.entity]
    if not old or state.generation ~= old.generation then return false, 'baseline_required' end
    if not newer(state, old) then return false, 'stale_move' end
    self.versions[state.entity] = {generation = state.generation, motion = state.motion, sequence = state.sequence}
    return true, copy(state)
end
function Receiver:forget(entity)
    if self.versions[entity] then
        self.versions[entity],self.count = nil,self.count-1
        return true
    end
    return false
end
return M
