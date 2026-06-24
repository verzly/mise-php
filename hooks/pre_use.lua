local php_versions = require("lib/php_versions")

local function normalize_version(value)
    if type(value) ~= "string" then
        return nil
    end

    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("^.-@", "")
    value = value:gsub("^v", "")

    if value == "" then
        return nil
    end

    return value
end

--- Resolves rolling PHP aliases before mise writes the selected version.
--- @param ctx table Context provided by vfox
--- @return table Version override
function PLUGIN:PreUse(ctx)
    local requested = normalize_version(ctx and ctx.version)

    if requested == nil or not php_versions.is_rolling_version(requested) then
        return { version = ctx.version }
    end

    local releases = self:Available(ctx or {})
    local version = php_versions.resolve_rolling_version(releases, requested)

    if version == nil then
        error("No PHP version found for rolling request: " .. requested)
    end

    return { version = version }
end
