// D1-b regression: in raw framing, returning data from onPacket must consume
// the whole input (not 0). Client sends 3 gapped packets; server echoes each
// by returning bytes. Server must observe exactly "p1","p2","p3" (each fully
// consumed), never an accumulation like "p1","p1p2","p1p2p3".
export default {
  __init() {
    xtimer.init(16);
    xnet.init();
    const PORT = 38813;
    const seen = [];
    const expect = ["p1", "p2", "p3"];

    xnet.listen(PORT, {
      onConnect(conn) { conn.setFraming("raw"); },
      onPacket(conn, data) {
        const s = String.fromCharCode.apply(null, Array.from(data));
        seen.push(s);
        return data; // echo; D1-b => consume len
      },
    });

    let client = null, i = 0;
    xnet.connect("127.0.0.1", PORT, {
      onConnect(conn) { conn.setFraming("raw"); client = conn; },
    });

    // send one packet per tick so loopback delivers them separately
    xtimer.add(40, function (self) {
      if (!client) return;            // wait until connected
      if (i < expect.length) { client.send(expect[i]); i++; return; }
      self.del();
      xtimer.add(120, () => {
        const ok = seen.length === 3 && seen[0] === "p1" &&
                   seen[1] === "p2" && seen[2] === "p3";
        xthread.stop(ok ? 0 : 1);
      }, 1);
    }, -1);

    xtimer.add(3000, () => xthread.stop(1), 1); // timeout => fail
  },
};
