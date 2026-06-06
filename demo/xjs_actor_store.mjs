// store actor: holds private key/value state and can call the math actor,
// exercising actor->actor rpc (reply must route back to THIS actor, not 0).
import { dispatch, onMessage, rpc } from "../scripts/xjs/xactor.mjs";

const data = new Map();
let mathRef = null;

onMessage(async (op, ...args) => {
  switch (op) {
    case "setMath": mathRef = args[0]; return "ok";
    case "set": data.set(args[0], args[1]); return "ok";
    case "get": return data.has(args[0]) ? data.get(args[0]) : null;
    case "sumViaMath": return await rpc(mathRef, "add", ...args);
    default: throw new Error("store: unknown op " + op);
  }
});

export default { __thread_handle: dispatch, __init() {} };
