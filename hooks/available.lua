--- Returns available PHP versions from GitHub php-src tags
--- @param ctx table Context provided by vfox
--- @return table Available versions
function PLUGIN:Available(ctx)
    local http = require("http")

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
