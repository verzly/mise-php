local env = require("lib/env")
local static_php = require("lib/static_php")

local function prebuilt_static_enabled(ctx)
    local options = (ctx and ctx.options) or {}
    return env.PREBUILT_STATIC or static_php.is_enabled(options.prebuilt_static)
end

local function prebuilt_static_flavor(ctx)
    local options = (ctx and ctx.options) or {}
    return options.prebuilt_static_flavor or env.PREBUILT_STATIC_FLAVOR
end

--- Returns available PHP versions from GitHub php-src tags
--- @param ctx table Context provided by vfox
--- @return table Available versions
function PLUGIN:Available(ctx)
    local http = require("http")

    if prebuilt_static_enabled(ctx) and static_php.is_supported_platform() then
        local flavor = prebuilt_static_flavor(ctx)
        print(static_php.warning(flavor))
        return static_php.available_versions(http, flavor)
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
