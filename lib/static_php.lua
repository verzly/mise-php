local env = require("lib/env")
local messages = require("lib/messages")

local M = {}

local QUIET = env.QUIET
local PREBUILT_STATIC_FLAVOR = env.PREBUILT_STATIC_FLAVOR

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

local function find_prebuilt_php_binary(sdkPath)
    local candidates = {
        sdkPath .. "/bin/php",
        sdkPath .. "/php",
        sdkPath .. "/buildroot/bin/php",
    }

    for _, candidate in ipairs(candidates) do
        local f = io.open(candidate, "r")
        if f then
            f:close()
            return candidate
        end
    end

    local result_file = "/tmp/mise-php-prebuilt-php-" .. os.time() .. ".txt"
    os.remove(result_file)

    os.execute("find '" .. sdkPath .. "' -type f -name php 2>/dev/null | head -n 1 > '" .. result_file .. "'")

    local f = io.open(result_file, "r")
    if not f then
        return nil
    end

    local candidate = f:read("*l")
    f:close()
    os.remove(result_file)

    if candidate == nil or candidate == "" then
        return nil
    end

    return candidate
end

function M.install(sdkPath, version)
    local tools = require("lib/tools")

    print("Preparing prebuilt static PHP...")

    local major, minor = version:match("^(%d+)%.(%d+)")
    major, minor = tonumber(major) or 0, tonumber(minor) or 0

    os.execute(string.format("mkdir -p '%s/bin' '%s/conf.d'", sdkPath, sdkPath))

    local php_bin = sdkPath .. "/bin/php"
    local php_exists = io.open(php_bin, "r")

    if php_exists then
        php_exists:close()
    else
        local candidate = find_prebuilt_php_binary(sdkPath)
        if not candidate then
            error(
                "\n\nFailed to prepare prebuilt static PHP.\n\n" ..
                "The downloaded static-php-cli archive did not contain a PHP CLI binary.\n" ..
                "Flavor: \27[93m" .. M.normalize_flavor(PREBUILT_STATIC_FLAVOR) .. "\27[0m\n" ..
                "Version: \27[93m" .. version .. "\27[0m\n"
            )
        end

        local copy_status = os.execute(string.format("cp '%s' '%s'", candidate, php_bin))
        if copy_status ~= 0 and copy_status ~= true then
            error(
                "\n\nFailed to prepare prebuilt static PHP.\n\n" ..
                "Could not copy the PHP binary into the expected bin directory.\n"
            )
        end
    end

    local chmod_status = os.execute('chmod +x "' .. php_bin .. '"' .. QUIET)
    if chmod_status ~= 0 and chmod_status ~= true then
        error(
            "\n\nFailed to prepare prebuilt static PHP.\n\n" ..
            "Could not make the PHP binary executable.\n"
        )
    end

    local confFile = io.open(sdkPath .. "/conf.d/php.ini", "w")
    if confFile then
        confFile:write("# Add system-wide PHP configuration options here\n")
        confFile:close()
    end

    local status = os.execute('"' .. php_bin .. '" --version > /dev/null 2>&1')
    if status ~= 0 and status ~= true then
        error(
            "\n\nPrebuilt static PHP installation appears to be broken: 'php --version' failed.\n\n" ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end

    print("Prebuilt static PHP installation complete!")

    if tools.has_extension_requests() then
        tools.warn_prebuilt_static_extensions_skipped()
    end

    if major > 8 or (major == 8 and minor >= 1) then
        tools.install_pie(sdkPath, version)
    end

    tools.install_composer(sdkPath, version)
end


return M
