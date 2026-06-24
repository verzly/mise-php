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
        return static_php.available_versions(http, flavor, ctx)
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

    local all_versions = {}
    for version in resp.body:gmatch("[^\n]+") do
        version = version:match("^%s*(.-)%s*$")

        if version ~= "" then
            table.insert(all_versions, php_versions.available_record(version))
        end
    end

    local result = php_versions.filter_for_available(all_versions, ctx)

    return php_versions.append_aliases(result, all_versions)
end
