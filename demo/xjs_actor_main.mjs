// Stage 2 addressing demo. Run from the repo root:
//   bin/xjs demo/xjs_actor_main.mjs
//
// Shows: many actors per OS thread (spawn), routing by [thread, actor],
// per-actor state isolation, actor->actor rpc with multi-hop reply routing,
// and a cross-thread default actor — all over the same rpc surface.
import { dispatch, rpc, spawn } from "../scripts/xjs/xactor.mjs";

const WORKER = xthread.WORKER_GRP1;

export default {
  __tick_ms: 10,
  __thread_handle: dispatch, // main is actor 0; replies route here

  __init() {
    xtimer.init(16);

    const math = spawn("demo/xjs_actor_math.mjs");   // [mainThread, 1]
    const store = spawn("demo/xjs_actor_store.mjs");  // [mainThread, 2]
    xthread.logInfo("spawned math @", JSON.stringify(math),
                    "store @", JSON.stringify(store));

    // A cross-thread worker hosting its own default actor (id 0).
    xthread.createThread(WORKER, "rpc-worker", "demo/xjs_rpc_worker.mjs");

    xtimer.delay(50, async () => {
      try {
        // routing to distinct local actors
        xthread.logInfo("math add(2,3,4) =", String(await rpc(math, "add", 2, 3, 4)));
        xthread.logInfo("math mul(2,3,4) =", String(await rpc(math, "mul", 2, 3, 4)));

        // per-actor private state
        await rpc(store, "set", "k", "v1");
        xthread.logInfo("store get(k) =", String(await rpc(store, "get", "k")));
        xthread.logInfo("store get(missing) =", String(await rpc(store, "get", "missing")));

        // actor -> actor rpc: store calls math, reply routes back to store (actor 2),
        // store then replies to main (actor 0) — multi-hop addressing
        await rpc(store, "setMath", math);
        xthread.logInfo("store sumViaMath(10,20,30) =",
                        String(await rpc(store, "sumViaMath", 10, 20, 30)));

        // cross-thread default actor over the same surface
        xthread.logInfo("worker add(100,1) =", String(await rpc(WORKER, "add", 100, 1)));

        // error propagation across actors
        try {
          await rpc(math, "boom");
        } catch (e) {
          xthread.logInfo("error propagated:", String(e.message));
        }

        xthread.logInfo("xjs actor addressing demo OK");
      } catch (e) {
        xthread.logError("demo failed:", String((e && e.stack) || e));
      } finally {
        xthread.stop(0);
      }
    });
  },

  __uninit() {
    xthread.logInfo("xjs actor demo stop");
  },
};
