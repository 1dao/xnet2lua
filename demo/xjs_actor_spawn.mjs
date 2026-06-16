// spawn/dispose self-teardown hardening test.
// Spawns many actors that each dispose THEMSELVES from inside their own handler.
// Teardown must be deferred to a safe reap point, so __uninit runs AFTER the
// handler returns — never on the stack of the running handler (which would free
// the context underneath it). Each child reports "BUG" to this default actor if
// its __uninit ran synchronously. Also exercises draining many dead actors per
// reap. Exit 0 = correct (deferred); Exit 1 = synchronous-teardown bug.
let bug = false;
export default {
  __init() {
    xtimer.init(16);
    const me = xthread.currentId();
    const N = 64;
    for (let i = 0; i < N; i++) {
      const c = xthread.spawn("demo/xjs_actor_child.mjs");   // c is the thread-local actor id
      xthread.send(me, c, "die");
    }
    xtimer.add(250, () => { xthread.stop(bug ? 1 : 0); }, 1);
  },
  __thread_handle(msg) {
    if (msg === "BUG") bug = true;
  },
  __uninit() {},
};
