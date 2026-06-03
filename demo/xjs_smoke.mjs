// L1 harness smoke test: prove bin/xjs.exe runs a script and reports exit code.
export default {
  __init() {
    xthread.logInfo("xjs L1 smoke start");
    let ok = (typeof xtimer === "object") && (typeof xnet === "object");
    xtimer.init(16);
    xtimer.delay(1, () => {
      xthread.logInfo("xjs L1 smoke timer fired");
      xthread.stop(ok ? 0 : 1);
    });
  },
};
