// Watchdog test actor. "spin" runs away (must be interrupted by the soft
// watchdog); "ping" replies "pong" to the default actor (must still be serviced
// after the runaway is broken).
export default {
  __init() {},
  __thread_handle(cmd) {
    if (cmd === "spin") {
      while (true) {}            // runaway CPU; the watchdog must break this
    } else if (cmd === "ping") {
      xthread.post(xthread.currentId(), "pong");   // reach this thread's default actor
    }
  },
  __uninit() {},
};
