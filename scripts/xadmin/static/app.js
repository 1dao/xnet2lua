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
        role: '',
        pollTimer: null,
        authMethods: {},
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
        // Only 401 means "not authenticated" -> re-login. A 403 means the caller
        // IS authenticated but lacks the role (e.g. a viewer hitting /api/exec);
        // those are handled inline so the user isn't bounced to the login page.
        if (resp && resp.status === 401) {
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
            STATE.authMethods = s.auth_methods || {};
            if (!s.configured) {
                applySetupMode(!!s.db_from_cfg);
                showView('setup');
                return;
            }
            if (!s.authenticated) {
                renderAuthMethods(STATE.authMethods);
                showView('login');
                return;
            }
            STATE.authed = true;
            STATE.username = s.username || '';
            STATE.role = s.role || '';
            enterConsole();
        }).catch(function () {
            // Server unreachable / proxy issue. Show login so the user can
            // retry; federated methods cannot be enumerated, but a password
            // attempt will surface the real failure.
            renderAuthMethods(STATE.authMethods || {});
            showView('login');
        });
    }

    // Populate the federated-login section (OAuth buttons, JWT form, mTLS
    // hint) based on what the server reports as available.
    function renderAuthMethods(methods) {
        methods = methods || {};
        var box = $('#auth-federated');
        var buttons = $('#auth-buttons');
        var jwtBox = $('#auth-jwt');
        var mtlsHint = $('#auth-mtls-hint');
        if (!box || !buttons) return;

        buttons.innerHTML = '';
        var oauthList = methods.oauth || [];
        var hasAny = oauthList.length > 0 || methods.jwt || methods.mtls || false;
        box.hidden = !hasAny;
        if (!hasAny) {
            jwtBox.hidden = true;
            mtlsHint.hidden = true;
            return;
        }

        oauthList.forEach(function (name) {
            var a = document.createElement('a');
            a.className = 'btn btn-secondary auth-oauth-btn';
            a.href = '/api/auth/oauth/' + encodeURIComponent(name) + '/start?next=' +
                encodeURIComponent(window.location.pathname || '/');
            a.textContent = '使用 ' + name + ' 登录';
            buttons.appendChild(a);
        });
        jwtBox.hidden = !methods.jwt;
        // mTLS is always informational here: if the cert were already
        // presented, the server would have authenticated the request and
        // we'd have gone straight into the console.
        mtlsHint.hidden = !methods.mtls;
    }

    // Exchange an HS256 JWT for a session cookie.
    function doJwtLogin(e) {
        if (e) e.preventDefault();
        var tok = ($('#li-jwt-token').value || '').trim();
        if (!tok) {
            setAuthMsg('#jwt-msg', '请输入 JWT', 'err');
            return;
        }
        setAuthMsg('#jwt-msg', '验证中...', '');
        fetch('/api/auth/jwt', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ token: tok }),
        })
            .then(function (r) { return r.json().then(function (d) { return [r, d]; }); })
            .then(function (pair) {
                var data = pair[1] || {};
                if (data.ok) {
                    setAuthMsg('#jwt-msg', '', '');
                    STATE.authed = true;
                    STATE.username = data.username || '';
                    STATE.role = data.role || '';
                    $('#li-jwt-token').value = '';
                    enterConsole();
                } else {
                    setAuthMsg('#jwt-msg', data.error || '验证失败', 'err');
                }
            })
            .catch(function (err) {
                setAuthMsg('#jwt-msg', '请求失败: ' + ((err && err.message) || err), 'err');
            });
    }

    // Surface ?auth_error=... that the OAuth callback route appends on failure.
    function consumeAuthError() {
        try {
            var u = new URL(window.location.href);
            var e = u.searchParams.get('auth_error');
            if (e) {
                setAuthMsg('#login-msg', 'SSO 登录失败: ' + e, 'err');
                u.searchParams.delete('auth_error');
                window.history.replaceState({}, '', u.pathname + (u.search ? u.search : '') + u.hash);
            }
        } catch (_) { /* old browser: ignore */ }
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
        var isAdmin = STATE.role === 'admin';
        var cu = $('#current-user');
        if (cu) cu.textContent = STATE.username
            ? ('👤 ' + STATE.username + (isAdmin ? '' : ' · 只读'))
            : '';
        var lo = $('#logout-btn');
        if (lo) lo.hidden = false;
        applyRoleUI();
        renderHeader();
        showPage('shell');
        Promise.all([fetchPeers(), fetchStats()]);
        startPolling();
    }

    // Reflect the principal's role: a non-admin (viewer / federated identity not
    // in XADMIN_ADMINS) can browse peers/stats but cannot run scripts or reload,
    // so disable those controls instead of letting the click bounce off the 403.
    function applyRoleUI() {
        var isAdmin = STATE.role === 'admin';
        ['#run-script', '#reload-process'].forEach(function (sel) {
            var el = $(sel);
            if (!el) return;
            el.disabled = !isAdmin;
            el.title = isAdmin ? '' : '需要管理员权限（当前为 viewer 只读）';
        });
        var script = $('#script');
        if (script) script.readOnly = !isAdmin;
        // Token issuance is admin-only -- hide the menu entry for viewers.
        var mt = $('#menu-tokens');
        if (mt) mt.hidden = !isAdmin;
        if (!isAdmin) setMeta('当前账户为 viewer（只读）：可查看节点/统计，不能执行脚本或 reload', 'err');
    }

    // Mint a scoped access token via POST /api/tokens (admin only).
    function generateToken() {
        var role = ($('#tk-role') || {}).value || 'viewer';
        var ttl = parseInt(($('#tk-ttl') || {}).value, 10) || 3600;
        var sub = (($('#tk-sub') || {}).value || '').trim();
        var meta = $('#tk-meta');
        function setTkMeta(t, cls) { if (meta) { meta.textContent = t || ''; meta.className = 'output-meta' + (cls ? ' ' + cls : ''); } }
        setTkMeta('生成中...', '');
        fetch('/api/tokens', {
            method: 'POST',
            headers: authHeaders(),
            body: JSON.stringify({ role: role, ttl_seconds: ttl, sub: sub }),
        })
            .then(function (r) { return r.json().then(function (d) { return [r, d]; }); })
            .then(function (pair) {
                var data = pair[1] || {};
                if (!data.ok) {
                    setTkMeta('生成失败: ' + (data.error || pair[0].status), 'err');
                    return;
                }
                var box = $('#tk-output-box');
                if (box) box.hidden = false;
                var out = $('#tk-output');
                if (out) out.textContent = data.token || '';
                var when = data.exp ? new Date(data.exp * 1000).toLocaleString() : '';
                setTkMeta('已生成 · 角色=' + data.role + ' · sub=' + data.sub + ' · 到期 ' + when, 'ok');
            })
            .catch(function (err) {
                setTkMeta('请求失败: ' + ((err && err.message) || err), 'err');
            });
    }

    function copyToken() {
        var out = $('#tk-output');
        if (!out || !out.textContent) return;
        var done = function () { var m = $('#tk-meta'); if (m) m.textContent = '已复制到剪贴板'; };
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(out.textContent).then(done, function () {});
        } else {
            var sel = window.getSelection(), range = document.createRange();
            range.selectNodeContents(out); sel.removeAllRanges(); sel.addRange(range);
            try { document.execCommand('copy'); done(); } catch (e) {}
        }
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
                    STATE.role = data.role || 'admin';
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
                    STATE.role = data.role || '';
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
                STATE.authMethods = {};
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

    // Wire up the JWT submit button (uses type=button so the parent form's
    // submit handler -- which is doLogin -- isn't triggered). consumeAuthError
    // runs once on load to surface any auth_error=... from the URL.
    var jwtBtn = document.getElementById('li-jwt-submit');
    if (jwtBtn) jwtBtn.addEventListener('click', doJwtLogin);
    consumeAuthError();

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
        if (STATE.role !== 'admin') {
            setMeta('当前为 viewer（只读），无法执行脚本', 'err');
            return;
        }
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
        if (STATE.role !== 'admin') {
            setMeta('当前为 viewer（只读），无法 reload', 'err');
            return;
        }
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

    var tkGen = $('#tk-generate');
    if (tkGen) tkGen.addEventListener('click', generateToken);
    var tkCopy = $('#tk-copy');
    if (tkCopy) tkCopy.addEventListener('click', copyToken);

    // Decide the initial view from the server-side session/setup state.
    checkSession();
})();
