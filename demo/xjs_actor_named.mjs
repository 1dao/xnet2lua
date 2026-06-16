// A named worker actor. Registers itself as "worker" so others can find it by
// name, and answers "ping" with "pong" to its thread's default actor.
export default {
  __init() { xthread.registerName("worker"); },
  __thread_handle(cmd) {
    if (cmd === "ping") xthread.post(xthread.currentId(), "pong");
  },
  __uninit() {},
};
