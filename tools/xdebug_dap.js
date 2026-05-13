#!/usr/bin/env node
"use strict";

const net = require("net");
const path = require("path");

function parseArgs(argv) {
    const opts = {
        listen: 4711,
        xdebugHost: "127.0.0.1",
        xdebugPort: 19090,
        cwd: process.cwd()
    };
    for (let i = 2; i < argv.length; i++) {
        const a = argv[i];
        const v = argv[i + 1];
        if (a === "--listen" && v) opts.listen = Number(argv[++i]);
        else if (a === "--xdebug-host" && v) opts.xdebugHost = argv[++i];
        else if (a === "--xdebug-port" && v) opts.xdebugPort = Number(argv[++i]);
        else if (a === "--cwd" && v) opts.cwd = argv[++i];
    }
    return opts;
}

function slash(p) {
    return String(p || "").replace(/\\/g, "/");
}

function toSource(cwd, file) {
    const f = slash(file);
    if (!f) return {};
    const absolute = /^[A-Za-z]:\//.test(f) || f.startsWith("/");
    const full = absolute ? path.normalize(f) : path.join(cwd, f);
    return { name: path.basename(full), path: full };
}

function toDebugPath(cwd, file) {
    let p = slash(file);
    const c = slash(cwd);
    if (p.toLowerCase().startsWith(c.toLowerCase() + "/")) {
        p = p.slice(c.length + 1);
    }
    return p;
}

function shortPath(file) {
    const f = slash(file);
    return f ? f.split("/").pop() : "";
}

function threadName(t) {
    const script = slash(t.script || "");
    const scriptName = shortPath(script) || script || "lua";
    if (t.stopped && t.file) {
        return `T${t.id} stopped ${slash(t.file)}:${t.line} (${scriptName})`;
    }
    return `T${t.id} ${t.stopped ? "stopped" : "running"} (${scriptName})`;
}

function stoppedText(t, reason) {
    const at = t.file ? `${slash(t.file)}:${t.line}` : "unknown";
    const script = t.script ? ` script=${slash(t.script)}` : "";
    return `[xnet] ${reason}: T${t.id} stopped at ${at}${script}`;
}

class DapWire {
    constructor(input, output, onMessage) {
        this.input = input;
        this.output = output;
        this.onMessage = onMessage;
        this.buf = Buffer.alloc(0);
        input.on("data", chunk => this.onData(chunk));
    }

    onData(chunk) {
        this.buf = Buffer.concat([this.buf, chunk]);
        for (;;) {
            const headerEnd = this.buf.indexOf("\r\n\r\n");
            if (headerEnd < 0) return;
            const header = this.buf.slice(0, headerEnd).toString("utf8");
            const m = /Content-Length:\s*(\d+)/i.exec(header);
            if (!m) throw new Error("missing DAP Content-Length");
            const len = Number(m[1]);
            const start = headerEnd + 4;
            if (this.buf.length < start + len) return;
            const body = this.buf.slice(start, start + len).toString("utf8");
            this.buf = this.buf.slice(start + len);
            this.onMessage(JSON.parse(body));
        }
    }

    send(msg) {
        const body = JSON.stringify(msg);
        this.output.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
    }
}

class XdebugClient {
    constructor(host, port) {
        this.host = host;
        this.port = port;
        this.sock = null;
        this.buf = "";
        this.queue = [];
        this.pending = null;
        this.initResolve = null;
        this.initReject = null;
        this.initializing = true;
    }

    connect() {
        return new Promise((resolve, reject) => {
            this.initResolve = resolve;
            this.initReject = reject;
            this.sock = net.createConnection({ host: this.host, port: this.port });
            this.sock.setEncoding("utf8");
            this.sock.on("connect", () => {});
            this.sock.on("data", data => this.onData(data));
            this.sock.on("error", err => this.fail(err));
            this.sock.on("close", () => this.fail(new Error("xdebug connection closed")));
        });
    }

    fail(err) {
        if (this.initReject) {
            this.initReject(err);
            this.initReject = null;
        }
        if (this.pending) {
            this.pending.reject(err);
            this.pending = null;
        }
        while (this.queue.length) this.queue.shift().reject(err);
    }

    onData(data) {
        this.buf += data;
        for (;;) {
            const i = this.buf.indexOf("\n");
            if (i < 0) return;
            const line = this.buf.slice(0, i).replace(/\r$/, "");
            this.buf = this.buf.slice(i + 1);
            this.onLine(line);
        }
    }

    onLine(line) {
        if (this.initializing) {
            if (line === "END") {
                this.initializing = false;
                if (this.initResolve) this.initResolve();
                this.initResolve = null;
                this.initReject = null;
            }
            return;
        }
        if (!this.pending) return;
        if (line === "END") {
            const done = this.pending;
            this.pending = null;
            done.resolve(done.lines);
            this.pump();
        } else {
            this.pending.lines.push(line);
        }
    }

    command(text) {
        return new Promise((resolve, reject) => {
            this.queue.push({ text, resolve, reject, lines: [] });
            this.pump();
        });
    }

    pump() {
        if (this.pending || !this.queue.length || !this.sock) return;
        this.pending = this.queue.shift();
        this.sock.write(this.pending.text + "\n");
    }

    close() {
        if (this.sock) {
            this.sock.write("quit\n");
            this.sock.end();
        }
    }
}

class Session {
    constructor(socket, opts, onClose) {
        this.socket = socket;
        this.opts = { ...opts };
        this.onClose = onClose;
        this.seq = 1;
        this.xdbg = null;
        this.pollTimer = null;
        this.threads = new Map();
        this.breakpoints = new Map();
        this.frames = new Map();
        this.variables = new Map();
        this.nextFrameId = 1000;
        this.nextVarId = 1;
        this.stopReasons = new Map();
        this.wire = new DapWire(socket, socket, msg => this.handle(msg));
        socket.on("close", () => this.close());
    }

    sendResponse(req, body, success = true, message) {
        const res = {
            type: "response",
            seq: this.seq++,
            request_seq: req.seq,
            command: req.command,
            success
        };
        if (message) res.message = message;
        if (body !== undefined) res.body = body;
        this.wire.send(res);
    }

    sendEvent(event, body) {
        this.wire.send({ type: "event", seq: this.seq++, event, body });
    }

    output(text) {
        this.sendEvent("output", { category: "console", output: text.endsWith("\n") ? text : text + "\n" });
    }

    async handle(req) {
        try {
            if (req.type !== "request") return;
            const fn = this["on_" + req.command];
            if (fn) await fn.call(this, req, req.arguments || {});
            else this.sendResponse(req, {});
        } catch (err) {
            this.sendResponse(req, {}, false, err && err.message ? err.message : String(err));
        }
    }

    async ensureXdebug(args) {
        if (this.xdbg) return;
        this.opts.xdebugHost = args.xdebugHost || args.host || this.opts.xdebugHost;
        this.opts.xdebugPort = Number(args.xdebugPort || args.port || this.opts.xdebugPort);
        this.opts.cwd = args.cwd || this.opts.cwd;
        this.xdbg = new XdebugClient(this.opts.xdebugHost, this.opts.xdebugPort);
        await this.xdbg.connect();
        this.output(`xnet xdebug connected: ${this.opts.xdebugHost}:${this.opts.xdebugPort}`);
    }

    async on_initialize(req) {
        this.sendResponse(req, {
            supportsConfigurationDoneRequest: true,
            supportsPauseRequest: true,
            supportsTerminateRequest: true,
            supportsSingleThreadExecutionRequests: true,
            supportsStepInTargetsRequest: false,
            supportsEvaluateForHovers: false,
            supportsSetVariable: false
        });
        this.sendEvent("initialized", {});
    }

    async on_attach(req, args) {
        await this.ensureXdebug(args);
        await this.applyBreakpoints();
        this.startPolling();
        this.sendResponse(req, {});
    }

    async on_launch(req, args) {
        await this.on_attach(req, args);
    }

    async on_configurationDone(req) {
        this.sendResponse(req, {});
        this.pollThreads().catch(() => {});
    }

    async on_setBreakpoints(req, args) {
        const file = args.source && args.source.path ? args.source.path : "";
        const lines = (args.breakpoints || []).map(b => b.line).filter(Boolean);
        this.breakpoints.set(file, lines);
        await this.applyBreakpoints();
        this.sendResponse(req, {
            breakpoints: lines.map(line => ({ verified: true, line }))
        });
    }

    async applyBreakpoints() {
        if (!this.xdbg) return;
        await this.xdbg.command("clear");
        for (const [file, lines] of this.breakpoints) {
            const p = toDebugPath(this.opts.cwd, file);
            for (const line of lines) await this.xdbg.command(`break ${p} ${line}`);
        }
    }

    async on_threads(req) {
        const threads = await this.getThreads();
        this.sendResponse(req, {
            threads: threads.map(t => ({ id: t.id, name: threadName(t) }))
        });
    }

    parseThreads(lines) {
        const out = [];
        for (const line of lines) {
            if (!line || line.startsWith("OK ")) continue;
            const p = line.split("\t");
            out.push({
                id: Number(p[0]),
                stopped: p[1] === "stopped",
                file: p[2] || "",
                line: Number(p[3] || 0),
                script: p.slice(4).join("\t")
            });
        }
        return out.filter(t => t.id > 0);
    }

    async getThreads() {
        if (!this.xdbg) return [];
        return this.parseThreads(await this.xdbg.command("threads"));
    }

    startPolling() {
        if (this.pollTimer) return;
        this.pollTimer = setInterval(() => this.pollThreads().catch(() => {}), 250);
        this.pollThreads().catch(() => {});
    }

    async pollThreads() {
        const list = await this.getThreads();
        const next = new Map();
        for (const t of list) {
            const prev = this.threads.get(t.id);
            next.set(t.id, t);
            if (!prev) this.sendEvent("thread", { reason: "started", threadId: t.id });
            if (t.stopped && (!prev || !prev.stopped || prev.file !== t.file || prev.line !== t.line)) {
                const reason = this.stopReasons.get(t.id) || "breakpoint";
                this.stopReasons.delete(t.id);
                this.output(stoppedText(t, reason));
                this.sendEvent("stopped", { reason, threadId: t.id, allThreadsStopped: false });
            }
        }
        for (const [id] of this.threads) {
            if (!next.has(id)) this.sendEvent("thread", { reason: "exited", threadId: id });
        }
        this.threads = next;
    }

    async on_stackTrace(req, args) {
        const tid = Number(args.threadId);
        const lines = await this.xdbg.command(`stack ${tid}`);
        const frames = [];
        for (const line of lines) {
            if (!line || line.startsWith("OK ")) continue;
            if (line.startsWith("ERR ")) break;
            const p = line.split("\t");
            const id = this.nextFrameId++;
            const level = Number(p[0]);
            this.frames.set(id, { threadId: tid, frame: level });
            const name = p[3] || "?";
            frames.push({
                id,
                name: level === 0 ? `[T${tid}] ${name}` : name,
                source: toSource(this.opts.cwd, p[1] || ""),
                line: Number(p[2] || 0),
                column: 1
            });
        }
        this.sendResponse(req, { stackFrames: frames, totalFrames: frames.length });
    }

    async on_scopes(req, args) {
        const frame = this.frames.get(Number(args.frameId));
        if (!frame) {
            this.sendResponse(req, { scopes: [] });
            return;
        }
        const threadRef = this.nextVarId++;
        const localsRef = this.nextVarId++;
        this.variables.set(threadRef, { kind: "thread", threadId: frame.threadId });
        this.variables.set(localsRef, { kind: "locals", ...frame });
        this.sendResponse(req, {
            scopes: [
                { name: "XNet Thread", variablesReference: threadRef, expensive: false },
                { name: "Locals", variablesReference: localsRef, expensive: false }
            ]
        });
    }

    async on_variables(req, args) {
        const scope = this.variables.get(Number(args.variablesReference));
        if (!scope) {
            this.sendResponse(req, { variables: [] });
            return;
        }
        if (scope.kind === "thread") {
            const t = this.threads.get(scope.threadId) || { id: scope.threadId };
            const stoppedAt = t.file ? `${slash(t.file)}:${t.line}` : "";
            this.sendResponse(req, {
                variables: [
                    { name: "xnet_thread_id", value: String(scope.threadId), variablesReference: 0 },
                    { name: "status", value: t.stopped ? "stopped" : "running", variablesReference: 0 },
                    { name: "script", value: slash(t.script || ""), variablesReference: 0 },
                    { name: "stopped_at", value: stoppedAt, variablesReference: 0 }
                ]
            });
            return;
        }
        const lines = await this.xdbg.command(`locals ${scope.threadId} ${scope.frame}`);
        const variables = [];
        for (const line of lines) {
            if (!line || line.startsWith("OK ")) continue;
            if (line.startsWith("ERR ")) break;
            const i = line.indexOf("\t");
            if (i < 0) continue;
            variables.push({
                name: line.slice(0, i),
                value: line.slice(i + 1),
                variablesReference: 0
            });
        }
        this.sendResponse(req, { variables });
    }

    async resume(req, tid, command, reason, allThreadsContinued = false) {
        await this.xdbg.command(command);
        if (allThreadsContinued) {
            for (const [id, old] of this.threads) this.threads.set(id, { ...old, stopped: false });
        } else {
            const old = this.threads.get(tid);
            if (old) this.threads.set(tid, { ...old, stopped: false });
        }
        if (reason) this.stopReasons.set(tid, reason);
        this.sendEvent("continued", { threadId: tid, allThreadsContinued });
        this.sendResponse(req, { allThreadsContinued });
    }

    async on_continue(req, args) {
        const tid = Number(args.threadId);
        if (args.singleThread) await this.resume(req, tid, `continue ${tid}`);
        else await this.resume(req, tid, "continue all", undefined, true);
    }

    async on_next(req, args) {
        const tid = Number(args.threadId);
        await this.resume(req, tid, `step ${tid} over`, "step");
    }

    async on_stepIn(req, args) {
        const tid = Number(args.threadId);
        await this.resume(req, tid, `step ${tid} into`, "step");
    }

    async on_stepOut(req, args) {
        const tid = Number(args.threadId);
        await this.resume(req, tid, `step ${tid} out`, "step");
    }

    async on_pause(req, args) {
        const tid = Number(args.threadId);
        this.stopReasons.set(tid, "pause");
        await this.xdbg.command(`pause ${tid}`);
        this.sendResponse(req, {});
    }

    async on_disconnect(req) {
        this.sendResponse(req, {});
        this.close();
    }

    async on_terminate(req) {
        this.sendResponse(req, {});
        this.close();
    }

    async on_evaluate(req) {
        this.sendResponse(req, { result: "", variablesReference: 0 });
    }

    close() {
        if (this.pollTimer) clearInterval(this.pollTimer);
        this.pollTimer = null;
        if (this.xdbg) this.xdbg.close();
        this.xdbg = null;
        if (this.onClose) {
            const cb = this.onClose;
            this.onClose = null;
            cb();
        }
    }
}

const opts = parseArgs(process.argv);
console.error("xnet-xdebug-dap starting");
const server = net.createServer(socket => {
    let session = null;
    session = new Session(socket, opts, () => {
        server.close(() => process.exit(0));
    });
});

server.on("error", err => {
    console.error("xnet-xdebug-dap error:", err.message);
    process.exit(1);
});

server.listen(opts.listen, "127.0.0.1", () => {
    console.error(`xnet-xdebug-dap listening on 127.0.0.1:${opts.listen}`);
});
