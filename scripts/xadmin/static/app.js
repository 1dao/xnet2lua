(function () {
    'use strict';

    var STATE = {
        self: '',
        peers: [],
        stats: null,
        token: null,
        tokenRequired: false,
        authed: false,
        username: '',
        pollTimer: null,
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

    // -----------------------------------------------------------------------
    // Auth gate (setup / login) vs. console
    // -----------------------------------------------------------------------
    function showView(which) {
        // which: 'setup' | 'login' | 'console'
        var gate = $('#auth-gate');
        var consoleEl = $('#console');
        var setupView = $('#setup-view');
        var loginView = $('#login-view');
        if (which === 'console') {
            gate.hidden = true;
            consoleEl.hidden = false;
            return;
        }
        gate.hidden = false;
        consoleEl.hidden = true;
        setupView.hidden = (which !== 'setup');
        loginView.hidden = (which !== 'login');
    }

    // Returns true (and re-shows the login view) if the response indicates the
    // session is gone; callers should then bail out of rendering.
    function handleAuthLoss(resp) {
        if (resp && (resp.status === 401 || resp.status === 403)) {
            stopPolling();
            STATE.authed = false;
            checkSession();
            return true;
        }
        return false;
    }

    function fetchSession() {
        return fetch('/api/session', { headers: { 'Accept': 'application/json' } })
            .then(function (r) { return r.json(); })
            .catch(function () { return null; });
    }

    function checkSession() {
        return fetchSession().then(function (s) {
            s = s || {};
            STATE.self = s.self || STATE.self || '';
            STATE.tokenRequired = !!s.token_required;
            if (!s.configured) {
                applySetupMode(!!s.db_from_cfg);
                showView('setup');
                return;
            }
            if (!s.authenticated) {
                showView('login');
                return;
            }
            STATE.authed = true;
            STATE.username = s.username || '';
            enterConsole();
        });
    }

    // When xnet.cfg already provides the DB, hide the DB form and only ask for
    // the default admin account.
    function applySetupMode(dbFromCfg) {
        var dbFields = $('#su-db-fields');
        if (dbFields) dbFields.hidden = !!dbFromCfg;
        var sub = $('#setup-sub');
        if (sub) {
            sub.textContent = dbFromCfg
                ? '数据库已由 xnet.cfg 配置，请设置默认管理员账户。'
                : '尚未检测到数据库配置。请填写 MySQL 连接信息与默认管理员账户。';
        }
    }

    function enterConsole() {
        showView('console');
        var cu = $('#current-user');
        if (cu) cu.textContent = STATE.username ? ('👤 ' + STATE.username) : '';
        var lo = $('#logout-btn');
        if (lo) lo.hidden = false;
        renderHeader();
        showPage('shell');
        Promise.all([fetchPeers(), fetchStats()]);
        startPolling();
    }

    function startPolling() {
        stopPolling();
        STATE.pollTimer = setInterval(function () {
            if (!STATE.authed) return;
            fetchPeers();
            fetchStats();
        }, 5000);
    }

    function stopPolling() {
        if (STATE.pollTimer) {
            clearInterval(STATE.pollTimer);
            STATE.pollTimer = null;
        }
    }

    function setAuthMsg(id, text, cls) {
        var el = $(id);
        if (!el) return;
        el.textContent = text || '';
        el.className = 'auth-msg' + (cls ? ' ' + cls : '');
    }

    function doSetup(e) {
        if (e) e.preventDefault();
        var payload = {
            host: $('#su-host').value.trim(),
            port: $('#su-port').value.trim(),
            user: $('#su-user').value.trim(),
            password: $('#su-password').value,
            database: $('#su-database').value.trim(),
            admin_user: $('#su-admin-user').value.trim(),
            admin_pass: $('#su-admin-pass').value,
        };
        if (!payload.admin_user || !payload.admin_pass) {
            setAuthMsg('#setup-msg', '请填写管理员账户与密码', 'err');
            return;
        }
        setAuthMsg('#setup-msg', '正在连接数据库并初始化...', '');
        fetch('/api/setup', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
        })
            .then(function (r) { return r.json().then(function (d) { return [r, d]; }); })
            .then(function (pair) {
                var data = pair[1] || {};
                if (data.ok) {
                    setAuthMsg('#setup-msg', '初始化成功，正在进入控制台...', 'ok');
                    STATE.authed = true;
                    STATE.username = data.username || payload.admin_user;
                    enterConsole();
                } else {
                    setAuthMsg('#setup-msg', '初始化失败: ' + (data.error || '未知错误'), 'err');
                }
            })
            .catch(function (err) {
                setAuthMsg('#setup-msg', '请求失败: ' + ((err && err.message) || err), 'err');
            });
    }

    function doLogin(e) {
        if (e) e.preventDefault();
        var payload = {
            username: $('#li-user').value.trim(),
            password: $('#li-password').value,
        };
        if (!payload.username || !payload.password) {
            setAuthMsg('#login-msg', '请输入账户与密码', 'err');
            return;
        }
        setAuthMsg('#login-msg', '登录中...', '');
        fetch('/api/login', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
        })
            .then(function (r) { return r.json().then(function (d) { return [r, d]; }); })
            .then(function (pair) {
                var data = pair[1] || {};
                if (data.ok) {
                    setAuthMsg('#login-msg', '', '');
                    STATE.authed = true;
                    STATE.username = data.username || payload.username;
                    $('#li-password').value = '';
                    enterConsole();
                } else {
                    setAuthMsg('#login-msg', data.error || '登录失败', 'err');
                }
            })
            .catch(function (err) {
                setAuthMsg('#login-msg', '请求失败: ' + ((err && err.message) || err), 'err');
            });
    }

    function doLogout() {
        fetch('/api/logout', { method: 'POST' })
            .then(function () {})
            .catch(function () {})
            .then(function () {
                stopPolling();
                STATE.authed = false;
                STATE.username = '';
                var lo = $('#logout-btn');
                if (lo) lo.hidden = true;
                showView('login');
            });
    }

    // -----------------------------------------------------------------------
    // Console
    // -----------------------------------------------------------------------
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
            .then(function (r) {
                if (handleAuthLoss(r)) return null;
                return r.json();
            })
            .then(function (data) {
                if (!data) return;
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
            .then(function (r) {
                if (handleAuthLoss(r)) return null;
                return r.json();
            })
            .then(function (data) {
                if (!data) return;
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
        if (auth) auth.textContent = STATE.tokenRequired ? '需要 token' : '会话登录';
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
                if (r.status === 401 && STATE.tokenRequired) {
                    if (promptToken() != null) {
                        return send().then(function (rr) {
                            return rr.json().then(function (d) { return [rr, d]; });
                        });
                    }
                    return [r, { ok: false, error: 'cancelled' }];
                }
                if (handleAuthLoss(r)) return [r, { ok: false, error: '会话已失效，请重新登录' }];
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
                if (r.status === 401 && STATE.tokenRequired) {
                    if (promptToken() != null) {
                        return send().then(function (rr) {
                            return rr.json().then(function (d) { return [rr, d]; });
                        });
                    }
                    return [r, { ok: false, error: 'cancelled' }];
                }
                if (handleAuthLoss(r)) return [r, { ok: false, error: '会话已失效，请重新登录' }];
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

    // -----------------------------------------------------------------------
    // Wiring
    // -----------------------------------------------------------------------
    $('#run-script').addEventListener('click', runScript);
    var reloadBtn = $('#reload-process');
    if (reloadBtn) reloadBtn.addEventListener('click', reloadProcess);
    $('#refresh-peers').addEventListener('click', fetchPeers);
    var rp2 = $('#refresh-peers-2');
    if (rp2) rp2.addEventListener('click', fetchPeers);
    var rs = $('#refresh-stats');
    if (rs) rs.addEventListener('click', fetchStats);

    var setupForm = $('#setup-view');
    if (setupForm) setupForm.addEventListener('submit', doSetup);
    var loginForm = $('#login-view');
    if (loginForm) loginForm.addEventListener('submit', doLogin);
    var logoutBtn = $('#logout-btn');
    if (logoutBtn) logoutBtn.addEventListener('click', doLogout);

    // Decide the initial view from the server-side session/setup state.
    checkSession();
})();
