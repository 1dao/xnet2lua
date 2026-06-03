// S3 regression: a timer callback that deletes its own timer must not UAF.
export default {
  __init() {
    xtimer.init(16);
    let firedOnce = 0;
    // repeat=1 timer: last_call path; callback deletes itself.
    xtimer.add(1, function (self) { firedOnce++; self.del(); }, 1);

    // infinite timer: deletes itself after 3 fires, then ends the process.
    let n = 0;
    xtimer.add(1, function (self) {
      n++;
      if (n >= 3) {
        self.del();
        xthread.stop(firedOnce === 1 ? 0 : 1);
      }
    }, -1);

    // hard timeout guard => fail if we never finished.
    xtimer.add(2000, () => xthread.stop(1), 1);
  },
};
