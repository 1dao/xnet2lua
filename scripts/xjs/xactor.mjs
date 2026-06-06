// xactor — Stage 3 actor messaging for xjs (addressing + rpc + supervision).
//
// An actor is one JSContext. One OS thread (xthread) hosts many actors; each
// has an id unique within its thread. An address is [threadId, actorId];
// actorId 0 is the thread's default actor, which also acts as that thread's
// local supervisor (it handles the reserved control ops below).
//
//   JS-visible envelope = [kind, corrId, fromThread, fromActor, ...payload]
//     kind 0  cast / 1 req / 2 rep / 3 err
//   (toActor rides in the C frame prefix and is consumed before dispatch.)
//
// Reserved ops (sent to [thread, 0], run on that thread by its default actor):
//   __spawn(script)        -> actorId      create an actor locally
//   __dispose(actor, why)  -> bool         run its __uninit, free it, notify monitors
//   __monitor(actor, who)  -> true         register a down-watcher
//   __down(thread, actor, why)  (cast)     delivered to a watcher; drives onDown()
//
// Wiring: set `__thread_handle: dispatch` on the exported lifecycle object,
// then register app logic with onMessage(fn). Module state is per actor.

const KIND_CAST = 0;
const KIND_REQ = 1;
const KIND_REP = 2;
const KIND_ERR = 3;

const pending = new Map(); // corrId -> { settle }
let seq = 0;
let userHandler = () => undefined;

// Supervision state (meaningful on a thread's default actor).
const monitors = new Map();   // local actorId -> watcher addresses[]
const downHandlers = [];

function toAddr(addr) {
  if (typeof addr === "number") return [addr, 0];
  if (Array.isArray(addr)) return [addr[0], addr[1] | 0];
  if (addr && typeof addr === "object") return [addr.thread, addr.actor | 0];
  throw new Error("xactor: bad address");
}

// Address of the calling actor: [thisThread, thisActor]. Use as a reply target.
export function self() {
  return [xthread.currentId(), xthread.selfActor()];
}

function addMonitor(actorId, watcher) {
  const list = monitors.get(actorId) || [];
  list.push(watcher);
  monitors.set(actorId, list);
}

function notifyDown(actorId, reason) {
  const ws = monitors.get(actorId);
  if (!ws) return;
  monitors.delete(actorId);
  for (const w of ws) cast(w, "__down", xthread.currentId(), actorId, reason);
}

// Register a callback fired when a monitored actor goes down: fn([thread,actor], reason).
export function onDown(fn) { if (typeof fn === "function") downHandlers.push(fn); }
function fireDown(addr, reason) { for (const h of downHandlers) h(addr, reason); }

// Reserved control handlers, dispatched before userHandler.
const controlReq = {
  __spawn: (p) => xthread.spawn(p[1]),
  __dispose: (p) => { notifyDown(p[1], p[2]); return xthread.disposeActor(p[1]); },
  __monitor: (p) => { addMonitor(p[1], p[2]); return true; },
};
const controlCast = {
  __down: (p) => fireDown([p[1], p[2]], p[3]),
};

// Register the handler for incoming casts and requests. async is supported.
export function onMessage(fn) {
  userHandler = (typeof fn === "function") ? fn : (() => undefined);
}

// Fire-and-forget message. No reply, no waiting.
export function cast(addr, ...payload) {
  const [thread, actor] = toAddr(addr);
  return xthread.send(thread, actor, KIND_CAST, 0,
                      xthread.currentId(), xthread.selfActor(), ...payload);
}

// Request/reply. Resolves with the handler's result.
export function rpc(addr, ...payload) {
  return rpcTimeout(0, addr, ...payload);
}

export function rpcTimeout(timeoutMs, addr, ...payload) {
  const [thread, actor] = toAddr(addr);
  const corrId = ++seq;
  return new Promise((resolve, reject) => {
    let timer = null;
    if (timeoutMs > 0 && typeof xtimer === "object") {
      timer = xtimer.delay(timeoutMs, () => {
        if (pending.delete(corrId)) reject(new Error("rpc timeout"));
      });
    }
    pending.set(corrId, {
      settle(ok, value) {
        if (timer) timer.del();
        ok ? resolve(value) : reject(new Error(String(value)));
      },
    });
    xthread.send(thread, actor, KIND_REQ, corrId,
                 xthread.currentId(), xthread.selfActor(), ...payload);
  });
}

// Spawn an actor on THIS thread. Returns its [thread, actor].
export function spawn(script) {
  return [xthread.currentId(), xthread.spawn(script)];
}

// Spawn an actor on a (possibly remote) thread. Returns its [thread, actor].
export async function spawnOn(thread, script) {
  if (thread === xthread.currentId()) return spawn(script);
  const id = await rpc([thread, 0], "__spawn", script);
  return [thread, id];
}

// Terminate an actor (runs its __uninit) and notify its monitors.
export function kill(addr, reason = "killed") {
  const [thread, actor] = toAddr(addr);
  return rpc([thread, 0], "__dispose", actor, reason);
}

// Ask to be notified (via onDown) when addr goes down. watcher defaults to self().
export function monitor(addr, watcher) {
  const [thread, actor] = toAddr(addr);
  return rpc([thread, 0], "__monitor", actor, watcher || self());
}

// Supervise a script on a thread: spawn it, and respawn whenever it goes down.
export function supervise(thread, script) {
  const sup = { ref: null, restarts: 0 };
  sup.start = async () => {
    sup.ref = await spawnOn(thread, script);
    await monitor(sup.ref);
    return sup.ref;
  };
  onDown((addr) => {
    if (sup.ref && addr[0] === sup.ref[0] && addr[1] === sup.ref[1]) {
      sup.restarts++;
      sup.start();
    }
  });
  return sup;
}

// The message handler. Register as `__thread_handle: dispatch`.
export function dispatch(kind, corrId, fromThread, fromActor, ...payload) {
  if (kind === KIND_REP || kind === KIND_ERR) {
    const p = pending.get(corrId);
    if (p) {
      pending.delete(corrId);
      p.settle(kind === KIND_REP, payload[0]);
    }
    return;
  }

  const op = payload[0];

  if (kind === KIND_REQ) {
    const ctl = (typeof op === "string") ? controlReq[op] : null;
    const run = ctl ? () => ctl(payload) : () => userHandler(...payload);
    Promise.resolve().then(run).then(
      (result) => xthread.send(fromThread, fromActor, KIND_REP, corrId,
                               xthread.currentId(), xthread.selfActor(), result ?? null),
      (err) => xthread.send(fromThread, fromActor, KIND_ERR, corrId,
                            xthread.currentId(), xthread.selfActor(),
                            String((err && err.message) || err)));
    return;
  }

  // kind === KIND_CAST
  const ctl = (typeof op === "string") ? controlCast[op] : null;
  Promise.resolve().then(ctl ? () => ctl(payload) : () => userHandler(...payload));
}

export default {
  self, onMessage, cast, rpc, rpcTimeout,
  spawn, spawnOn, kill, monitor, onDown, supervise, dispatch,
};
