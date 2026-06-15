-- xagent/skills/loader.lua — discover SKILL.md files on disk.
--
-- Scans two scopes for `<dir>/<name>/SKILL.md`:
--   user    : ~/.xagent/skills/
--   project : <cwd>/.xagent/skills/
-- Project wins on a name collision (loaded second). Uses xutils.scan_dir
-- (recursive, files-only) and filters to the top-level SKILL.md of each skill
-- directory, so nested skill assets (scripts, templates) are ignored.

local xutils = require('xutils')
local fs     = dofile('scripts/core/share/xfs.lua')
local path   = dofile('scripts/core/share/xpath.lua')
local fm     = require('xagent.skills.frontmatter')

local M = {}

local function load_one_dir(dir, source)
    local skills, warnings = {}, {}
    local entries = xutils.scan_dir(dir)
    if not entries then return { skills = skills, warnings = warnings } end

    for _, e in ipairs(entries) do
        local rel = (e.rel or ''):gsub('\\', '/')
        local skill_name = rel:match('^([^/]+)/SKILL%.md$')
        if skill_name then
            local raw = fs.read_file(e.path)
            if raw then
                local split = fm.split(raw)
                if split.parse_error then
                    warnings[#warnings + 1] = '[skills] Skipping ' .. skill_name ..
                        ': invalid frontmatter (' .. split.parse_error .. ')'
                else
                    local front = fm.normalize(split.raw, split.body)
                    local desc = front.description
                    if not desc or desc == '' then desc = fm.extract_fallback_description(split.body) end
                    if not desc or desc == '' then desc = front.name or skill_name end
                    skills[#skills + 1] = {
                        name        = front.name or skill_name,
                        description = desc,
                        when_to_use = front.when_to_use,
                        body        = split.body,
                        file_path   = e.path,
                        base_dir    = path.dirname(e.path),
                        source      = source,
                        frontmatter = front,
                    }
                end
            end
        end
    end
    return { skills = skills, warnings = warnings }
end

-- load_all(cwd) -> { skills = {...}, warnings = {...} }
function M.load_all(cwd)
    local home = (fs.home():gsub('[/\\]+$', ''))
    local user_dir = home .. '/.xagent/skills'
    local proj_dir = (tostring(cwd or '.'):gsub('[/\\]+$', '')) .. '/.xagent/skills'

    local u = load_one_dir(user_dir, 'user')
    local p = load_one_dir(proj_dir, 'project')

    local by_name, order = {}, {}
    local function merge(list)
        for _, s in ipairs(list) do
            if not by_name[s.name] then order[#order + 1] = s.name end
            by_name[s.name] = s   -- later call (project) overrides
        end
    end
    merge(u.skills)
    merge(p.skills)

    local merged = {}
    for _, nm in ipairs(order) do merged[#merged + 1] = by_name[nm] end

    local warnings = {}
    for _, w in ipairs(u.warnings) do warnings[#warnings + 1] = w end
    for _, w in ipairs(p.warnings) do warnings[#warnings + 1] = w end
    return { skills = merged, warnings = warnings }
end

return M
