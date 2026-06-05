-- xadmin_store.lua -- persistence + auth helpers for the xadmin console.
--
-- Two responsibilities:
--   1. Persist the MySQL connection settings in a small JSON file outside the
--      database (chicken-and-egg: we cannot read DB settings *from* the DB).
--      Default path is `xadmin_db.json` in the working directory; override with
--      the XADMIN_DATA_FILE config key.
--   2. Wrap the MySQL service thread (xthread.MYSQL) to manage the schema,
--      accounts and login sessions. All hashing is delegated to MySQL's SHA2()
--      so no Lua-side crypto is required.
--
-- This module is stateless and reload-safe: it is dofile()d on both the main
-- thread (lifecycle) and every HTTP worker (request handling). Functions read
-- the JSON config on demand so a freshly-configured worker sees it immediately.

local xutils = require('xutils')

local M = {}

local DEFAULT_DATA_FILE = 'xadmin_db.json'
local SESSION_TTL_SEC = 7 * 24 * 3600  -- login sessions live one week
local QUERY_TIMEOUT_MS = 8000

-- ---------------------------------------------------------------------------
-- Paths / identifiers
-- ---------------------------------------------------------------------------
function M.data_file()
    return xutils.get_config('XADMIN_DATA_FILE', DEFAULT_DATA_FILE)
end

-- MySQL identifiers are interpolated, not bound, so restrict them hard.
local function safe_ident(name, fallback)
    name = tostring(name or '')
    if name:match('^[%w_]+$') then return name end
    return fallback
end

-- ---------------------------------------------------------------------------
-- SQL string escaping (values are interpolated; always quote through this).
-- ---------------------------------------------------------------------------
function M.sql_quote(value)
    value = tostring(value == nil and '' or value)
    value = value:gsub('\\', '\\\\')
    value = value:gsub('\0', '\\0')
    value = value:gsub('\n', '\\n')
    value = value:gsub('\r', '\\r')
    value = value:gsub("'", "\\'")
    value = value:gsub('"', '\\"')
    value = value:gsub('\26', '\\Z')
    return "'" .. value .. "'"
end

-- ---------------------------------------------------------------------------
-- Random tokens / salts (hex). Prefer the OS CSPRNG, fall back to math.random.
-- ---------------------------------------------------------------------------
local seeded = false
local function random_hex(bytes)
    bytes = bytes or 16
    local f = io.open('/dev/urandom', 'rb')
    if f then
        local raw = f:read(bytes)
        f:close()
        if raw and #raw == bytes then
            local out = {}
            for i = 1, bytes do
                out[i] = string.format('%02x', string.byte(raw, i))
            end
            return table.concat(out)
        end
    end
    if not seeded then
        math.randomseed(os.time() + (os.clock() * 1e6) % 1e9)
        seeded = true
    end
    local out = {}
    for i = 1, bytes do
        out[i] = string.format('%02x', math.random(0, 255))
    end
    return table.concat(out)
end
M.random_hex = random_hex

-- ---------------------------------------------------------------------------
-- DB config: xnet.cfg (XADMIN_DB_*) overlaid on a JSON file
-- ---------------------------------------------------------------------------
-- Read the raw JSON file. Returns a config table, or a default-shaped table
-- with configured=false when the file is missing/unreadable/invalid.
local function read_db_file()
    local path = M.data_file()
    local f = io.open(path, 'rb')
    if not f then
        return { configured = false, db = {} }
    end
    local raw = f:read('*a')
    f:close()
    if not raw or raw == '' then
        return { configured = false, db = {} }
    end
    local cfg, err = xutils.json_unpack(raw)
    if type(cfg) ~= 'table' then
        return { configured = false, db = {}, error = tostring(err or 'invalid config') }
    end
    if type(cfg.db) ~= 'table' then cfg.db = {} end
    cfg.configured = cfg.configured and true or false
    return cfg
end

-- DB connection overrides from xnet.cfg (XADMIN_DB_*). Empty/absent keys are
-- treated as "not set" so they fall back to the JSON file. Returns a table of
-- only the fields that were actually provided (others are nil).
local function config_db_overrides()
    local function v(key)
        local s = tostring(xutils.get_config(key, '') or '')
        if s == '' then return nil end
        return s
    end
    return {
        host     = v('XADMIN_DB_HOST'),
        port     = v('XADMIN_DB_PORT'),
        user     = v('XADMIN_DB_USER'),
        password = v('XADMIN_DB_PASSWORD'),
        database = v('XADMIN_DB_DATABASE'),
    }
end

-- Resolve the effective DB config by overlaying xnet.cfg on the JSON file.
-- Per field, a non-empty xnet.cfg value wins; otherwise the JSON value is used.
-- Returns a table:
--   .configured   whether the admin account has been initialised (JSON flag)
--   .db           the merged connection params (host/port/user/password/database)
--   .db_from_cfg  true when xnet.cfg alone fully specifies the DB (host+user+
--                 database) -- the web setup can then skip the DB fields
--   .error        set when the JSON file is present but unparseable
function M.load_db_config()
    local file_cfg = read_db_file()
    local jdb = file_cfg.db or {}
    local ov = config_db_overrides()

    local db = {
        host     = ov.host or jdb.host,
        port     = tonumber(ov.port) or jdb.port,
        user     = ov.user or jdb.user,
        password = (ov.password ~= nil) and ov.password or jdb.password,
        database = ov.database or jdb.database,
    }
    local db_from_cfg = ov.host ~= nil and ov.user ~= nil and ov.database ~= nil

    return {
        configured  = file_cfg.configured and true or false,
        db          = db,
        db_from_cfg = db_from_cfg,
        error       = file_cfg.error,
    }
end

function M.save_db_config(cfg)
    local path = M.data_file()
    local body, err = xutils.json_pack(cfg)
    if not body then
        return false, 'json pack failed: ' .. tostring(err)
    end
    local f, oerr = io.open(path, 'wb')
    if not f then
        return false, 'open failed: ' .. tostring(oerr)
    end
    f:write(body)
    f:close()
    return true
end

function M.is_configured()
    return M.load_db_config().configured
end

-- Normalize raw user input into a clean DB-config table.
function M.normalize_db(raw)
    raw = raw or {}
    local port = tonumber(raw.port) or 3306
    return {
        host = (raw.host and raw.host ~= '') and tostring(raw.host) or '127.0.0.1',
        port = port,
        user = tostring(raw.user or 'root'),
        password = tostring(raw.password or ''),
        database = safe_ident(raw.database, 'xadmin'),
    }
end

-- ---------------------------------------------------------------------------
-- MySQL access (through the shared xthread.MYSQL service thread)
-- ---------------------------------------------------------------------------
-- Must be called from within a coroutine (HTTP session / RPC handler) because
-- xthread.rpc yields. Returns (ok, result_or_err).
--
-- xthread.rpc yields back three values: (channel_ok, app_ok, result):
--   channel_ok = false  -> RPC transport failure; app_ok holds the error text
--   channel_ok = true   -> the xmysql_query handler returned (app_ok, result),
--                          where result is the row set or an error string.
function M.query(sql, timeout_ms)
    if not xthread.MYSQL then
        return false, 'xthread.MYSQL is not defined'
    end
    local channel_ok, app_ok, result =
        xthread.rpc(xthread.MYSQL, 'xmysql_query', timeout_ms or QUERY_TIMEOUT_MS, sql)
    if not channel_ok then
        return false, tostring(app_ok or 'rpc failed')
    end
    return app_ok and true or false, result
end

-- Create the database + accounts/sessions tables. The pool connects without a
-- default database so this works even before the database exists; everything
-- is fully qualified with the configured database name.
function M.ensure_schema(database)
    local db = safe_ident(database, 'xadmin')
    local q = '`' .. db .. '`'

    local ok, r = M.query(
        'CREATE DATABASE IF NOT EXISTS ' .. q ..
        ' DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci')
    if not ok then return false, 'create database: ' .. tostring(r) end

    ok, r = M.query(
        'CREATE TABLE IF NOT EXISTS ' .. q .. '.`accounts` (' ..
        'id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,' ..
        'username VARCHAR(64) NOT NULL,' ..
        'salt CHAR(32) NOT NULL,' ..
        'password_hash CHAR(64) NOT NULL,' ..
        'created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,' ..
        'updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,' ..
        'UNIQUE KEY uk_username (username)' ..
        ') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4')
    if not ok then return false, 'create accounts: ' .. tostring(r) end

    ok, r = M.query(
        'CREATE TABLE IF NOT EXISTS ' .. q .. '.`sessions` (' ..
        'token CHAR(64) NOT NULL PRIMARY KEY,' ..
        'username VARCHAR(64) NOT NULL,' ..
        'created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,' ..
        'expires_at DATETIME NOT NULL,' ..
        'KEY idx_expires (expires_at)' ..
        ') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4')
    if not ok then return false, 'create sessions: ' .. tostring(r) end

    return true
end

-- Insert or update an account; password is hashed via MySQL SHA2(salt||pw).
function M.upsert_account(database, username, password)
    local db = safe_ident(database, 'xadmin')
    username = tostring(username or '')
    if username == '' then return false, 'username is empty' end
    if tostring(password or '') == '' then return false, 'password is empty' end

    local salt = random_hex(16)  -- 32 hex chars
    local sql = 'INSERT INTO `' .. db .. '`.`accounts` (username, salt, password_hash) VALUES (' ..
        M.sql_quote(username) .. ', ' .. M.sql_quote(salt) .. ', ' ..
        'SHA2(CONCAT(' .. M.sql_quote(salt) .. ', ' .. M.sql_quote(password) .. '), 256))' ..
        ' ON DUPLICATE KEY UPDATE salt = VALUES(salt), password_hash = VALUES(password_hash)'
    local ok, r = M.query(sql)
    if not ok then return false, tostring(r) end
    return true
end

-- Returns (true, username) on a credential match, (false, reason) otherwise.
function M.verify_login(database, username, password)
    local db = safe_ident(database, 'xadmin')
    local sql = 'SELECT username FROM `' .. db .. '`.`accounts` WHERE username = ' ..
        M.sql_quote(username) ..
        ' AND password_hash = SHA2(CONCAT(salt, ' .. M.sql_quote(password) .. '), 256) LIMIT 1'
    local ok, r = M.query(sql)
    if not ok then return false, tostring(r) end
    local row = r and r.rows and r.rows[1]
    if not row then return false, 'invalid username or password' end
    return true, row.username
end

-- Create a login session row and return its opaque token.
function M.create_session(database, username)
    local db = safe_ident(database, 'xadmin')
    local token = random_hex(32)  -- 64 hex chars
    local sql = 'INSERT INTO `' .. db .. '`.`sessions` (token, username, expires_at) VALUES (' ..
        M.sql_quote(token) .. ', ' .. M.sql_quote(username) ..
        ', DATE_ADD(NOW(), INTERVAL ' .. tostring(SESSION_TTL_SEC) .. ' SECOND))'
    local ok, r = M.query(sql)
    if not ok then return nil, tostring(r) end
    return token
end

-- Returns username for a live (non-expired) session token, else nil.
function M.validate_session(database, token)
    token = tostring(token or '')
    if not token:match('^%x+$') or #token ~= 64 then return nil end
    local db = safe_ident(database, 'xadmin')
    local sql = 'SELECT username FROM `' .. db .. '`.`sessions` WHERE token = ' ..
        M.sql_quote(token) .. ' AND expires_at > NOW() LIMIT 1'
    local ok, r = M.query(sql)
    if not ok then return nil, tostring(r) end
    local row = r and r.rows and r.rows[1]
    if not row then return nil end
    return row.username
end

function M.destroy_session(database, token)
    token = tostring(token or '')
    if token == '' then return true end
    local db = safe_ident(database, 'xadmin')
    local ok = M.query('DELETE FROM `' .. db .. '`.`sessions` WHERE token = ' .. M.sql_quote(token))
    return ok and true or false
end

-- Best-effort GC of expired sessions; safe to call opportunistically.
function M.gc_sessions(database)
    local db = safe_ident(database, 'xadmin')
    return M.query('DELETE FROM `' .. db .. '`.`sessions` WHERE expires_at <= NOW()')
end

return M
