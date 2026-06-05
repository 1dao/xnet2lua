// Stage 1 rpc demo: main thread spawns a worker actor and drives it with
// await rpc(...). Run from the repo root:  bin/xjs demo/xjs_rpc_main.mjs
import { dispatch, rpc, rpcTimeout } from "../scripts/xjs/xactor.mjs";

const WORKER = xthread.WORKER_GRP1;

export default {
  __tick_ms: 10,
  __thread_handle: dispatch, // replies route back through dispatch

  __init() {
    xtimer.init(16);
    // Worker path is resolved against the process cwd (the repo root).
    xthread.createThread(WORKER, "rpc-worker", "demo/xjs_rpc_worker.mjs");

    // Let the worker boot, then exercise the rpc surface.
    xtimer.delay(50, async () => {
      try {
        xthread.logInfo("add(2,3,4) =", String(await rpc(WORKER, "add", 2, 3, 4)));
        xthread.logInfo("echo =", String(await rpc(WORKER, "echo", "hello")));
        xthread.logInfo("slow =", String(await rpcTimeout(1000, WORKER, "slow", "x")));

        try {
          await rpc(WORKER, "boom");
        } catch (e) {
          xthread.logInfo("error propagated:", String(e.message));
        }

        try {
          await rpcTimeout(20, WORKER, "slow", "y"); // 20ms < 50ms => times out
        } catch (e) {
          xthread.logInfo("timeout works:", String(e.message));
        }

        xthread.logInfo("xjs rpc demo OK");
      } catch (e) {
        xthread.logError("demo failed:", String((e && e.stack) || e));
      } finally {
        xthread.stop(0);
      }
    });
  },

  __uninit() {
    xthread.logInfo("xjs rpc demo stop");
  },
};
