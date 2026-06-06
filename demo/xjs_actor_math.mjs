// math actor: stateless compute, addressed as a spawned actor on its thread.
import { dispatch, onMessage } from "../scripts/xjs/xactor.mjs";

onMessage((op, ...args) => {
  switch (op) {
    case "add": return args.reduce((a, b) => a + b, 0);
    case "mul": return args.reduce((a, b) => a * b, 1);
    default: throw new Error("math: unknown op " + op);
  }
});

export default { __thread_handle: dispatch, __init() {} };
