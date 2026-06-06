// actor host: a worker thread whose default actor accepts remote spawns,
// disposes and monitors via xactor's reserved control ops (in dispatch).
import { dispatch } from "../scripts/xjs/xactor.mjs";

export default {
  __thread_handle: dispatch,
  __init() {
    xtimer.init(16);
    xthread.logInfo("actor host ready");
  },
};
