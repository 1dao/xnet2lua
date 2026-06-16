// L2 soft-watchdog test. A spawned actor dead-loops inside its handler. With a
// per-turn CPU deadline set, the watchdog interrupts the runaway and the thread
// keeps serving its other actors (the "worker" still answers "ping" with
// "pong"). Exit 0 = thread survived the runaway; without the watchdog the
// thread would freeze and this never completes.
let pong = false;
export default {
  __init() {
    xtimer.init(16);
    xthread.setDeadline(100);             // 100ms CPU budget per actor turn
    const me = xthread.currentId();
    const spinner = xthread.spawn("demo/xjs_actor_spin.mjs");
    const worker = xthread.spawn("demo/xjs_actor_spin.mjs");
    xthread.send(me, spinner, "spin");    // runaway; watchdog must break it
    xthread.send(me, worker, "ping");     // must still be serviced afterwards
    xtimer.add(1500, () => xthread.stop(pong ? 0 : 1), 1);
  },
  __thread_handle(msg) {
    if (msg === "pong") pong = true;
  },
  __uninit() {},
};
