(function () {
    'use strict';

    var STATE = {
        self: '',
        peers: [],
        stats: null,
        token: null,
        tokenRequired: false,
    };

    function $(sel) { return document.querySelector(sel); }
    function $$(sel) { return Array.prototype.slice.call(document.querySelectorAll(sel)); }

    function escapeHtml(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function showPage(name) {
        $$('.menu-item').forEach(function (el) {
            el.classList.toggle('active', el.dataset.page === name);
        });
        $$('.page').forEach(function (el) {
            el.hidden = (el.dataset.page !== name);
        });
        if (name === 'peers') renderPeerTable();
        if (name === 'stats') renderStatsPanel();
    }

    $$('.menu-item').forEach(function (el) {
        el.addEventListener('click', function () { showPage(el.dataset.page); });
    });

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

    function fetchPeers() {
        return fetch('/api/peers')
            .then(function (r) { return r.json(); })
            .then(function (data) {
                STATE.self = data.self || '';
                STATE.peers = data.peers || [];
                STATE.tokenRequired = !!data.token_required;
                renderPeerSelect();
                renderPeerTable();
                renderHeader();
            })
            .catch(function (err) {
                console.error('peers fetch failed', err);
            });
    }

    function fetchStats() {
        return fetch('/api/stats')
            .then(function (r) { return r.json(); })
            .then(function (data) {
                STATE.stats = data || {};
                renderStatsPanel();
            })
            .catch(function (err) {
                console.error('stats fetch failed', err);
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

        if (keep) {
            for (var i = 0; i < sel.options.length; i++) {
                if (sel.options[i].value === keep) {
                    sel.selectedIndex = i;
                    renderReloadSelect();
                    return;
                }
            }
        }
        sel.selectedIndex = 0;
        renderReloadSelect();
    }

    function renderReloadSelect() {
        var sel = $('#reload-target');
        if (!sel) return;
        var keep = sel.value || 'all';
        sel.innerHTML = '';

        var optAll = document.createElement('option');
        optAll.value = 'all';
        optAll.textContent = 'all processes';
        sel.appendChild(optAll);

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

        for (var i = 0; i < sel.options.length; i++) {
            if (sel.options[i].value === keep) {
                sel.selectedIndex = i;
                return;
            }
        }
        sel.selectedIndex = 0;
    }

    function renderPeerTable() {
        var tbody = $('#peer-rows');
        if (!tbody) return;
        tbody.innerHTML = '';

        var rowSelf = document.createElement('tr');
        rowSelf.innerHTML = '<td class="role-self">' + escapeHtml(STATE.self) + '</td><td>self</td><td>-</td>';
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

    function fmtLocalTime(ms) {
        if (!ms) return '';
        var d = new Date(ms);
        if (isNaN(d.getTime())) return '';
        return '更新时间: ' + d.toLocaleString();
    }

    function renderStatsPanel() {
        var stats = STATE.stats || {};
        var summary = stats.summary || {};
        var threads = stats.threads || [];

        var selfEl = $('#stats-self');
        if (selfEl) selfEl.textContent = stats.self || STATE.self || '-';
        var countEl = $('#stats-thread-count');
        if (countEl) countEl.textContent = String(summary.thread_count || threads.length || 0);
        var qtotEl = $('#stats-queue-total');
        if (qtotEl) qtotEl.textContent = String(summary.queue_depth_total || 0);
        var qpeakEl = $('#stats-queue-peak');
        if (qpeakEl) {
            var peak = summary.peak_queue_depth || 0;
            var peakName = summary.peak_queue_thread_name || '';
            var peakId = summary.peak_queue_thread_id || 0;
            if (peakName || peakId) qpeakEl.textContent = String(peak) + ' (#' + peakId + ' ' + peakName + ')';
            else qpeakEl.textContent = String(peak);
        }
        var atEl = $('#stats-at');
        if (atEl) atEl.textContent = fmtLocalTime(stats.at_ms);

        var tbody = $('#stats-rows');
        if (!tbody) return;
        tbody.innerHTML = '';

        threads.forEach(function (st) {
            var tr = document.createElement('tr');
            tr.innerHTML =
                '<td>' + escapeHtml(st.id) + '</td>' +
                '<td>' + escapeHtml(st.name || '') + '</td>' +
                '<td>' + escapeHtml(st.queue_depth || 0) + '</td>' +
                '<td>' + escapeHtml(st.queue_max || 0) + '</td>';
            tbody.appendChild(tr);
        });
    }

    function setMeta(text, cls) {
        var m = $('#run-meta');
        if (!m) return;
        m.textContent = text || '';
        m.className = 'output-meta' + (cls ? ' ' + cls : '');
    }

    function setOutput(text) {
        var out = $('#output');
        if (out) out.textContent = text || '';
    }

    function runScript() {
        var targetEl = $('#target');
        var scriptEl = $('#script');
        var target = targetEl ? (targetEl.value || 'self') : 'self';
        var script = scriptEl ? scriptEl.value : '';
        if (!script || !script.trim()) {
            setMeta('脚本为空', 'err');
            return;
        }

        setMeta('运行中...', '');
        setOutput('');

        var t0 = performance.now();
        function send() {
            return fetch('/api/exec', {
                method: 'POST',
                headers: authHeaders(),
                body: JSON.stringify({ target: target, script: script }),
            });
        }

        send()
            .then(function (r) {
                if (r.status === 401) {
                    if (promptToken() != null) {
                        return send().then(function (rr) {
                            return rr.json().then(function (d) { return [rr, d]; });
                        });
                    }
                    return [r, { ok: false, error: 'cancelled' }];
                }
                return r.json().then(function (d) { return [r, d]; });
            })
            .then(function (pair) {
                var data = pair[1] || {};
                var dt = (performance.now() - t0).toFixed(0);
                var lines = [];
                if (data.stdout && data.stdout.length) lines.push(data.stdout);
                if (data.result && data.result.length) lines.push('-- result --\n' + data.result);
                if (data.error) lines.push('-- error --\n' + data.error);
                if (!data.ok && lines.length === 0) lines.push('(no output)');
                setOutput(lines.join('\n\n') || '(no output)');
                var who = data.target || target;
                setMeta(
                    (data.ok ? 'ok' : 'failed') + '  · target=' + who + '  · ' + dt + 'ms',
                    data.ok ? 'ok' : 'err'
                );
            })
            .catch(function (err) {
                setOutput(String((err && err.message) || err));
                setMeta('请求失败', 'err');
            });
    }

    function reloadProcess() {
        var targetEl = $('#reload-target');
        var target = targetEl ? (targetEl.value || 'all') : 'all';
        setMeta('reload running...', '');

        var t0 = performance.now();
        function send() {
            return fetch('/api/reload', {
                method: 'POST',
                headers: authHeaders(),
                body: JSON.stringify({ target: target }),
            });
        }

        send()
            .then(function (r) {
                if (r.status === 401) {
                    if (promptToken() != null) {
                        return send().then(function (rr) {
                            return rr.json().then(function (d) { return [rr, d]; });
                        });
                    }
                    return [r, { ok: false, error: 'cancelled' }];
                }
                return r.json().then(function (d) { return [r, d]; });
            })
            .then(function (pair) {
                var data = pair[1] || {};
                var dt = (performance.now() - t0).toFixed(0);
                var rows = [];
                (data.results || []).forEach(function (r) {
                    rows.push((r.ok ? 'ok' : 'failed') + '  ' + (r.target || '') + '  ' + (r.result || ''));
                });
                if (data.error) rows.push('error  ' + data.error);
                setOutput(rows.join('\n') || '(no output)');
                setMeta(
                    (data.ok ? 'reload ok' : 'reload failed') + '  · target=' + (data.target || target) + '  · ' + dt + 'ms',
                    data.ok ? 'ok' : 'err'
                );
            })
            .catch(function (err) {
                setOutput(String((err && err.message) || err));
                setMeta('reload request failed', 'err');
            });
    }

    document.addEventListener('keydown', function (e) {
        if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
            var shellPage = $('.page[data-page="shell"]');
            if (shellPage && shellPage.hidden === false) {
                e.preventDefault();
                runScript();
            }
        }
    });

    $('#run-script').addEventListener('click', runScript);
    var reloadBtn = $('#reload-process');
    if (reloadBtn) reloadBtn.addEventListener('click', reloadProcess);
    $('#refresh-peers').addEventListener('click', fetchPeers);
    var rp2 = $('#refresh-peers-2');
    if (rp2) rp2.addEventListener('click', fetchPeers);
    var rs = $('#refresh-stats');
    if (rs) rs.addEventListener('click', fetchStats);

    showPage('shell');
    Promise.all([fetchPeers(), fetchStats()]);

    setInterval(function () {
        fetchPeers();
        fetchStats();
    }, 5000);
})();
