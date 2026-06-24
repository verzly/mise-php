local static_php = require("lib/static_php")
local php_versions = require("lib/php_versions")

--- Returns available PHP versions from GitHub php-src tags
--- @param ctx table Context provided by vfox
--- @return table Available versions
function PLUGIN:Available(ctx)
    local http = require("http")

    if static_php.is_requested(ctx) and static_php.is_supported_platform() then
        local flavor = static_php.requested_flavor(ctx)
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

    local versions = {}
    for version in resp.body:gmatch("[^\n]+") do
        if version ~= "" then
            table.insert(versions, version)
        end
    end

    php_versions.sort_for_default_resolution(versions)

    local result = {}
    for _, version in ipairs(versions) do
        table.insert(result, { version = version })
    end

    return result
end
