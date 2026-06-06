// counter actor: private state + an __uninit hook, to show graceful teardown
// on kill and fresh state after a supervised restart.
import { dispatch, onMessage } from "../scripts/xjs/xactor.mjs";

let n = 0;

onMessage((op) => {
  if (op === "inc") return ++n;
  if (op === "get") return n;
  throw new Error("counter: unknown op " + op);
});

export default {
  __thread_handle: dispatch,
  __init() {},
  __uninit() { xthread.logInfo("counter __uninit at n=" + n); },
};
