local M = {}

M.BASE_URL = "https://dl.static-php.dev/static-php-cli"
M.DEFAULT_FLAVOR = "bulk"
M.DEFAULT_SAPI = "cli"

local FLAVORS = {
    ["bulk"] = true,
    ["common"] = true,
    ["gnu-bulk"] = true,
    ["minimal"] = true,
}

local function is_blank(value)
    return value == nil or value == "" or value == false
end

function M.is_enabled(value)
    if value == true then
        return true
    end
    if value == nil or value == false then
        return false
    end

    value = tostring(value)
    return value ~= "" and value ~= "0" and value ~= "false"
end

function M.is_supported_platform()
    return RUNTIME.osType == "linux" or RUNTIME.osType == "darwin"
end

function M.normalize_flavor(value)
    if is_blank(value) then
        return M.DEFAULT_FLAVOR
    end

    value = tostring(value)
    if not FLAVORS[value] then
        error(
            "Unsupported prebuilt static PHP flavor: " .. value .. "\n" ..
            "Supported flavors: bulk, common, gnu-bulk, minimal"
        )
    end

    return value
end

function M.os_name()
    if RUNTIME.osType == "darwin" then
        return "macos"
    end

    if RUNTIME.osType == "linux" then
        return "linux"
    end

    return nil
end

function M.arch_name()
    local arch = string.lower(RUNTIME.archType or "")

    if arch == "amd64" or arch == "x64" or arch == "x86_64" then
        return "x86_64"
    end

    if arch == "arm64" or arch == "aarch64" then
        return "aarch64"
    end

    return arch
end

function M.asset_name(version, flavor)
    local os_name = M.os_name()
    local arch_name = M.arch_name()

    if os_name == nil or arch_name == "" then
        error("Prebuilt static PHP is only available on supported Linux and macOS architectures.")
    end

    return "php-" .. version .. "-" .. M.DEFAULT_SAPI .. "-" .. os_name .. "-" .. arch_name .. ".tar.gz"
end

function M.asset_url(version, flavor)
    flavor = M.normalize_flavor(flavor)
    return M.BASE_URL .. "/" .. flavor .. "/" .. M.asset_name(version, flavor)
end

local function version_key(version)
    local major, minor, patch, suffix = string.match(version, "^(%d+)%.(%d+)%.(%d+)(.*)")

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

local function version_greater_than(a, b)
    local a_major, a_minor, a_patch, a_suffix_order, a_suffix = version_key(a)
    local b_major, b_minor, b_patch, b_suffix_order, b_suffix = version_key(b)

    if a_major ~= b_major then return a_major > b_major end
    if a_minor ~= b_minor then return a_minor > b_minor end
    if a_patch ~= b_patch then return a_patch > b_patch end
    if a_suffix_order ~= b_suffix_order then return a_suffix_order > b_suffix_order end

    return a_suffix > b_suffix
end

function M.available_versions(http, flavor)
    flavor = M.normalize_flavor(flavor)

    local os_name = M.os_name()
    local arch_name = M.arch_name()

    if os_name == nil or arch_name == "" then
        return {}
    end

    local resp, err = http.get({
        url = M.BASE_URL .. "/" .. flavor .. "/",
        headers = {
            ["User-Agent"] = "verzly-mise-php",
        },
    })

    if err ~= nil or resp.status_code ~= 200 then
        error("Failed to fetch static-php-cli prebuilt binaries: " .. tostring(err))
    end

    local versions = {}
    local seen = {}
    local pattern = "php%-([0-9][0-9A-Za-z%.%-]*)%-" .. M.DEFAULT_SAPI .. "%-" .. os_name .. "%-" .. arch_name .. "%.tar%.gz"

    for version in resp.body:gmatch(pattern) do
        if not seen[version] then
            seen[version] = true
            table.insert(versions, version)
        end
    end

    table.sort(versions, version_greater_than)

    local result = {}
    for _, version in ipairs(versions) do
        table.insert(result, { version = version })
    end

    return result
end

function M.release(version, flavor)
    return {
        version = version,
        url = M.asset_url(version, flavor),
    }
end

function M.warning(flavor)
    flavor = M.normalize_flavor(flavor)

    return "\27[93mWarning:\27[0m " ..
        "Using static-php-cli prebuilt PHP binaries (" .. flavor .. "). " ..
        "Fewer PHP versions may be available than source builds, and new PHP versions may appear later."
end

return M
