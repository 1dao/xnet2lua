export default {
  __tick_ms: 10,

  __init() {
    xthread.logInfo("xjs demo start", XNET_MAIN_FILE);
    xtimer.delay(10, () => {
      xthread.logInfo("xjs demo timer fired", xtimer.format());
      xthread.stop(0);
    });
  },

  __uninit() {
    xthread.logInfo("xjs demo stop");
  },
};
