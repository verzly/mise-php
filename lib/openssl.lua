local php_versions = require("lib/php_versions")
local process = require("lib/process")

local openssl = {}

local cached_version

local function detect_version()
    if cached_version ~= nil then
        return cached_version or nil
    end

    local result = process.run("openssl version", { quiet = " 2>/dev/null" })
    if result.ok then
        cached_version = result.output:match("(%d+%.%d+%.?%d*)") or false
    else
        cached_version = false
    end

    return cached_version or nil
end

function openssl.at_least(major, minor)
    local version = detect_version()
    if version == nil then
        return false
    end

    local current_major, current_minor = version:match("^(%d+)%.(%d+)")
    current_major = tonumber(current_major) or 0
    current_minor = tonumber(current_minor) or 0

    if current_major ~= major then
        return current_major > major
    end

    return current_minor >= minor
end

-- OpenSSL 4.1 made ASN1_STRING opaque. PHP before 8.5.13 (and 8.4.x before
-- 8.4.28) reads its fields directly in ext/openssl and fails to compile.
function openssl.php_supports_4_1(version)
    if php_versions.at_least(version, 8, 6) then
        return true
    end
    if php_versions.at_least(version, 8, 5) then
        return not php_versions.greater_than("8.5.13", version)
    end
    if php_versions.at_least(version, 8, 4) then
        return not php_versions.greater_than("8.4.28", version)
    end

    return false
end

return openssl
