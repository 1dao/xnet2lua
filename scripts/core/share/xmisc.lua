-- xmisc.lua - small, unclassified pure-Lua helpers shared across modules.
--
-- A home for tiny utilities that don't belong to any one module: lenient
-- boolean parsing, whitespace trimming, nil-safe lowercasing. Dependency-free
-- and stateless, so any thread can `dofile` it. Keep it small -- promote
-- anything that grows real structure into its own module.

local M = {}

-- Lenient boolean parse. Accepts bool, 0|1, and the common string spellings
-- (true/false, yes/no, on/off, "1"/"0"); anything else (incl. nil) yields
-- `default`. Used for config flags from xnet.cfg / env.
function M.to_bool(v, default)
    if v == nil then return default end
    if v == true or v == 1 or v == '1' or v == 'true' or v == 'yes' or v == 'on' then
        return true
    end
    if v == false or v == 0 or v == '0' or v == 'false' or v == 'no' or v == 'off' then
        return false
    end
    return default
end

-- Trim leading/trailing ASCII whitespace. Always returns a single string
-- (the parens drop gsub's substitution count).
function M.trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Lowercase, nil-safe.
function M.lower(s)
    return string.lower(tostring(s or ''))
end

return M
