local http = require('http')
local util = require('util')
require('constants')

function PLUGIN:Available(ctx)
    local result = {}

    if not GITHUB_VERSIONS_URL or not GITHUB_RELEASES_URL then
        print("⚠️ GITHUB_VERSIONS_URL or GITHUB_RELEASES_URL is not set in constants.lua")
        return result
    end

    local resp, err = http.get({ url = GITHUB_VERSIONS_URL })
    if not resp or not resp.body then
        print("⚠️ Error fetching versions file: " .. tostring(err))
        return result
    end

    for line in resp.body:gmatch("[^\r\n]+") do
        if line and #line > 0 then
            local versionStr = line:gsub("^v", "")
            if util.compare_versions(versionStr, "5.3.2") >= 0 then
                table.insert(result, {
                    version = versionStr,
                    name = line,
                    url = GITHUB_RELEASES_URL .. "/download/" .. line .. "/"
                })
            end
        end
    end

    table.sort(result, function(a, b)
        return util.compare_versions(a.version, b.version) > 0
    end)

    if #result == 0 then
        print("⚠️ No available PHP versions were found in the versions file.")
    end

    return result
end
