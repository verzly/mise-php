local versions = {}

function versions.at_least(version, major, minor)
    local current_major, current_minor = tostring(version):match("^(%d+)%.(%d+)")
    current_major = tonumber(current_major) or 0
    current_minor = tonumber(current_minor) or 0

    if current_major > major then
        return true
    end

    return current_major == major and current_minor >= minor
end

local function sort_key(version)
    local major, minor, patch, suffix = tostring(version):match("^(%d+)%.(%d+)%.(%d+)(.*)")

    major = tonumber(major) or 0
    minor = tonumber(minor) or 0
    patch = tonumber(patch) or 0

    -- Stable releases sort after pre-release suffixes with the same numeric version.
    local suffix_order = 0
    if suffix ~= nil and suffix ~= "" then
        suffix_order = -1
    end

    return major, minor, patch, suffix_order, suffix or ""
end

function versions.greater_than(a, b)
    local a_major, a_minor, a_patch, a_suffix_order, a_suffix = sort_key(a)
    local b_major, b_minor, b_patch, b_suffix_order, b_suffix = sort_key(b)

    if a_major ~= b_major then return a_major > b_major end
    if a_minor ~= b_minor then return a_minor > b_minor end
    if a_patch ~= b_patch then return a_patch > b_patch end
    if a_suffix_order ~= b_suffix_order then return a_suffix_order > b_suffix_order end

    return a_suffix > b_suffix
end

return versions
