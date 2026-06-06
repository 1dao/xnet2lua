// Stage 3 supervision demo. Run from the repo root:
//   bin/xjs demo/xjs_sup_main.mjs
//
// Shows: cross-thread spawn, graceful __uninit on kill, monitor/down
// notification, and a supervisor that auto-respawns a downed actor.
import { dispatch, rpc, spawnOn, kill, monitor, onDown, supervise } from "../scripts/xjs/xactor.mjs";

const WORKER = xthread.WORKER_GRP1;
const settle = (ms) => new Promise((r) => xtimer.delay(ms, r));

export default {
  __tick_ms: 10,
  __thread_handle: dispatch, // main is actor 0; replies + __down route here

  __init() {
    xtimer.init(16);
    // The worker must run an xactor default actor to accept remote spawns.
    xthread.createThread(WORKER, "actor-host", "demo/xjs_host.mjs");

    xtimer.delay(60, async () => {
      try {
        // 1. cross-thread spawn: create a math actor ON the worker thread
        const m = await spawnOn(WORKER, "demo/xjs_actor_math.mjs");
        xthread.logInfo("spawned remote math @", JSON.stringify(m),
                        "add(5,6) =", String(await rpc(m, "add", 5, 6)));

        // 2. monitor + kill -> __uninit runs, monitor gets __down
        let down = null;
        onDown((addr, reason) => { down = [addr, reason]; });
        await monitor(m);
        await kill(m, "manual");
        await settle(25);
        xthread.logInfo("down notified:", JSON.stringify(down));

        // 3. supervised actor: kill it, supervisor auto-respawns with fresh state
        const sup = supervise(WORKER, "demo/xjs_counter.mjs");
        await sup.start();
        await rpc(sup.ref, "inc");
        xthread.logInfo("counter @", JSON.stringify(sup.ref),
                        "v =", String(await rpc(sup.ref, "get")));
        const old = sup.ref;
        await kill(sup.ref, "boom");
        await settle(40); // allow __down -> respawn -> re-monitor
        xthread.logInfo("restarted @", JSON.stringify(sup.ref),
                        "(was", JSON.stringify(old) + ")",
                        "restarts =", String(sup.restarts));
        xthread.logInfo("fresh counter get =", String(await rpc(sup.ref, "get")));

        xthread.logInfo("xjs supervision demo OK");
      } catch (e) {
        xthread.logError("demo failed:", String((e && e.stack) || e));
      } finally {
        xthread.stop(0);
      }
    });
  },

  __uninit() {
    xthread.logInfo("xjs sup demo stop");
  },
};
