local env = require("lib/env")
local static_php = require("lib/static_php")

local function option_enabled(value)
    if value == true then return true end
    if value == nil or value == false then return false end
    value = tostring(value)
    return value ~= "" and value ~= "0" and value ~= "false"
end

local function prebuilt_static_enabled(ctx)
    local options = (ctx and ctx.options) or {}
    return env.PREBUILT_STATIC or option_enabled(options.prebuilt_static)
end

--- Returns available PHP versions from GitHub php-src tags
--- @param ctx table Context provided by vfox
--- @return table Available versions
function PLUGIN:Available(ctx)
    local http = require("http")

    if prebuilt_static_enabled(ctx) and static_php.is_supported_platform() then
        if ctx == nil or ctx.suppress_static_php_warning ~= true then
            print(static_php.warning())
        end
        return static_php.available_versions(http)
    end

    local resp, err = http.get({
        url = "https://raw.githubusercontent.com/verzly/mise-php/cache/versions.txt",
        headers = {
            ["User-Agent"] = "verzly-mise-php",
        },
    })

    if err ~= nil or resp.status_code ~= 200 then
        error("Failed to fetch versions.txt: " .. tostring(err))
    end

    local result = {}
    for version in resp.body:gmatch("[^\n]+") do
        if version ~= "" then
            table.insert(result, { version = version })
        end
    end

    return result
end
