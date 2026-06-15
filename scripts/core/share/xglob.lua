-- xglob.lua — translate a glob to a Lua pattern and match.
-- Supports: *  (any run, not crossing '/'),  ** (any run, crossing '/'),
--           ?  (one char, not '/'),  literals. Paths are normalized to '/'.
-- Dependency-free; any thread can `dofile` it.

local M = {}

local MAGIC = { ['^']=true, ['$']=true, ['(']=true, [')']=true, ['%']=true,
                ['.']=true, ['[']=true, [']']=true, ['+']=true, ['-']=true }

function M.to_pattern(glob)
    glob = tostring(glob or ''):gsub('\\', '/')
    local out, i, n = { '^' }, 1, #glob
    while i <= n do
        local c = glob:sub(i, i)
        if c == '*' then
            if glob:sub(i + 1, i + 1) == '*' then
                out[#out + 1] = '.*'           -- ** crosses '/'
                i = i + 2
                if glob:sub(i, i) == '/' then i = i + 1 end   -- absorb the slash
            else
                out[#out + 1] = '[^/]*'         -- * stays within a segment
                i = i + 1
            end
        elseif c == '?' then
            out[#out + 1] = '[^/]'; i = i + 1
        elseif MAGIC[c] then
            out[#out + 1] = '%' .. c; i = i + 1
        else
            out[#out + 1] = c; i = i + 1
        end
    end
    out[#out + 1] = '$'
    return table.concat(out)
end

function M.match(glob, candidate)
    local pat = M.to_pattern(glob)
    candidate = tostring(candidate or ''):gsub('\\', '/')
    return candidate:match(pat) ~= nil
end

return M
