// L3 named-actor test. Spawn a worker that registers itself as "worker", then
// resolve it purely by name (no ref or thread known a priori) and message it.
// Exit 0 = resolved + reachable; 2 = name didn't resolve; 1 = no reply.
let pong = false;
export default {
  __init() {
    xtimer.init(16);
    xthread.spawn("demo/xjs_actor_named.mjs");   // registers "worker" in its __init
    const addr = xthread.whereis("worker");       // -> [thread, actor], or null
    if (addr === null) { xthread.stop(2); return; }
    xthread.send(addr[0], addr[1], "ping");
    xtimer.add(120, () => xthread.stop(pong ? 0 : 1), 1);
  },
  __thread_handle(msg) { if (msg === "pong") pong = true; },
  __uninit() {},
};
