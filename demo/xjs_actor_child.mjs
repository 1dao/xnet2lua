// Spawned actor for the spawn/dispose hardening test.
// On "die" it disposes ITSELF from inside its own message handler. Correct
// behavior: teardown (__uninit + context free) must be DEFERRED to a safe
// point, not run synchronously underneath the still-executing handler.
export default {
  __init() {},
  __thread_handle(cmd) {
    if (cmd === "die") {
      globalThis.__active = true;        // handler is on the stack
      xthread.disposeActor(xthread.selfActor());
      globalThis.__active = false;       // handler about to return
    }
  },
  __uninit() {
    // If teardown ran while the handler was still active, that's the bug.
    // Report it to the thread's default actor (id 0).
    if (globalThis.__active) {
      xthread.post(xthread.currentId(), "BUG");   // reach this thread's default actor
    }
  },
};
