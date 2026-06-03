// S2 regression: a server handler that closes its own connection inside
// onPacket (holding no other reference) must not UAF. Loopback in one context.
export default {
  __init() {
    xtimer.init(16);
    xnet.init();
    const PORT = 38815;
    let serverClosed = false, clientClosed = false;
    const done = () => { if (serverClosed && clientClosed) xthread.stop(0); };

    xnet.listen(PORT, {
      onConnect(conn) { conn.setFraming("raw"); },
      // return a value: forces packet_cb's post-call path (maybe_send_return_value)
      // to touch `conn` AFTER the close above could have freed it (the real UAF).
      onPacket(conn /*, data */) { conn.close("server-done"); return "pong"; },
      onClose() { serverClosed = true; done(); },
    });

    xnet.connect("127.0.0.1", PORT, {
      onConnect(conn) { conn.setFraming("raw"); conn.send("ping"); },
      onClose() { clientClosed = true; done(); },
    });

    xtimer.add(2000, () => xthread.stop(1), 1); // timeout => fail
  },
};
