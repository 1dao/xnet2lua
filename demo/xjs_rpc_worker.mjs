// rpc worker actor: serves requests sent via xactor.rpc().
import { dispatch, onMessage } from "../scripts/xjs/xactor.mjs";

onMessage((op, ...args) => {
  switch (op) {
    case "add":
      return args.reduce((a, b) => a + b, 0);
    case "echo":
      return args[0];
    case "slow":
      // Stand-in for an async call (e.g. an LLM request) that resolves later.
      return new Promise((res) => xtimer.delay(50, () => res("late:" + args[0])));
    default:
      throw new Error("unknown op: " + op);
  }
});

export default {
  __thread_handle: dispatch,
  __init() {
    xtimer.init(16); // needed by the "slow" op's xtimer.delay
    xthread.logInfo("rpc worker ready");
  },
};
