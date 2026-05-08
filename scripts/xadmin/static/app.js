(function () {
    'use strict';

    var STATE = {
        self: '',
        peers: [],
        token: null,
        tokenRequired: false,
    };

    function $(sel) { return document.querySelector(sel); }
    function $$(sel) { return Array.prototype.slice.call(document.querySelectorAll(sel)); }

    // --- Page switching ---------------------------------------------------
    function showPage(name) {
        $$('.menu-item').forEach(function (el) {
            el.classList.toggle('active', el.dataset.page === name);
        });
        $$('.page').forEach(function (el) {
            el.hidden = (el.dataset.page !== name);
        });
        if (name === 'peers') renderPeerTable();
    }
    $$('.menu-item').forEach(function (el) {
        el.addEventListener('click', function () { showPage(el.dataset.page); });
    });

    // --- Token handling ---------------------------------------------------
    function getToken() {
        if (STATE.token !== null) return STATE.token;
        try { STATE.token = localStorage.getItem('xadmin.token') || ''; }
        catch (e) { STATE.token = ''; }
        return STATE.token;
    }
    function promptToken() {
        var prev = getToken();
        var t = window.prompt('需要提供 X-Xadmin-Token：', prev || '');
        if (t === null) return null;
        STATE.token = t;
        try { localStorage.setItem('xadmin.token', t); } catch (e) {}
        return t;
    }
    function authHeaders() {
        var h = { 'Content-Type': 'application/json' };
        var t = getToken();
        if (t) h['X-Xadmin-Token'] = t;
        return h;
    }

    // --- Peer fetch -------------------------------------------------------
    function fetchPeers() {
        return fetch('/api/peers').then(function (r) { return r.json(); }).then(function (data) {
            STATE.self = data.self || '';
            STATE.peers = data.peers || [];
            STATE.tokenRequired = !!data.token_required;
            renderPeerSelect();
            renderPeerTable();
            renderHeader();
        }).catch(function (err) {
            console.error('peers fetch failed', err);
        });
    }

    function renderPeerSelect() {
        var sel = $('#target');
        if (!sel) return;
        var keep = sel.value;
        sel.innerHTML = '';
        var optSelf = document.createElement('option');
        optSelf.value = 'self';
        optSelf.textContent = STATE.self ? ('self (' + STATE.self + ')') : 'self';
        sel.appendChild(optSelf);
        STATE.peers.forEach(function (p) {
            var o = document.createElement('option');
            o.value = p.name;
            o.textContent = p.name;
            sel.appendChild(o);
        });
        // Restore selection if still present.
        if (keep) {
            for (var i = 0; i < sel.options.length; i++) {
                if (sel.options[i].value === keep) { sel.selectedIndex = i; return; }
            }
        }
        sel.selectedIndex = 0;
    }

    function renderPeerTable() {
        var tbody = $('#peer-rows');
        if (!tbody) return;
        tbody.innerHTML = '';
        var rowSelf = document.createElement('tr');
        rowSelf.innerHTML = '<td class="role-self">' + escapeHtml(STATE.self) + '</td><td>self</td><td>—</td>';
        tbody.appendChild(rowSelf);
        STATE.peers.forEach(function (p) {
            var tr = document.createElement('tr');
            tr.innerHTML = '<td>' + escapeHtml(p.name) + '</td><td>peer</td><td>' + (p.last_seen_ms || '?') + '</td>';
            tbody.appendChild(tr);
        });
    }

    function renderHeader() {
        var sn = $('#self-name');
        if (sn) sn.textContent = STATE.self || '(unknown)';
        var auth = $('#auth-state');
        if (auth) auth.textContent = STATE.tokenRequired ? '需要 token' : '无认证';
    }

    function escapeHtml(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    // --- Run script -------------------------------------------------------
    function setMeta(text, cls) {
        var m = $('#run-meta');
        if (!m) return;
        m.textContent = text || '';
        m.className = 'output-meta' + (cls ? ' ' + cls : '');
    }
    function setOutput(text) { $('#output').textContent = text || ''; }

    function runScript() {
        var target = $('#target').value || 'self';
        var script = $('#script').value;
        if (!script || !script.trim()) {
            setMeta('脚本为空', 'err');
            return;
        }
        setMeta('运行中…', '');
        setOutput('');

        var t0 = performance.now();
        function send() {
            return fetch('/api/exec', {
                method: 'POST',
                headers: authHeaders(),
                body: JSON.stringify({ target: target, script: script }),
            });
        }
        send().then(function (r) {
            if (r.status === 401) {
                if (promptToken() != null) {
                    return send().then(function (rr) { return rr.json().then(function (d) { return [rr, d]; }); });
                }
                return [r, { ok: false, error: 'cancelled' }];
            }
            return r.json().then(function (d) { return [r, d]; });
        }).then(function (pair) {
            var r = pair[0], data = pair[1];
            var dt = (performance.now() - t0).toFixed(0);
            var lines = [];
            if (data.stdout && data.stdout.length) lines.push(data.stdout);
            if (data.result && data.result.length) lines.push('-- result --\n' + data.result);
            if (data.error) lines.push('-- error --\n' + data.error);
            if (!data.ok && lines.length === 0) lines.push('(no output)');
            setOutput(lines.join('\n\n') || '(no output)');
            var who = data.target || target;
            setMeta(
                (data.ok ? '✓ ok' : '✗ failed') + '  · target=' + who + '  · ' + dt + 'ms',
                data.ok ? 'ok' : 'err'
            );
        }).catch(function (err) {
            setOutput(String(err && err.message || err));
            setMeta('请求失败', 'err');
        });
    }

    // --- Boot -------------------------------------------------------------
    document.addEventListener('keydown', function (e) {
        if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
            if ($('.page[data-page="shell"]').hidden === false) {
                e.preventDefault();
                runScript();
            }
        }
    });
    $('#run-script').addEventListener('click', runScript);
    $('#refresh-peers').addEventListener('click', fetchPeers);
    var rp2 = $('#refresh-peers-2');
    if (rp2) rp2.addEventListener('click', fetchPeers);

    showPage('shell');
    fetchPeers();
    // Refresh peer table every 5s so the dropdown reflects new arrivals.
    setInterval(fetchPeers, 5000);
})();
