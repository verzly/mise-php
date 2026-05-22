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
    ["spc-max"] = true,
    ["spc-min"] = true,
}

local WINDOWS_FLAVOR_ALIASES = {
    ["bulk"] = "spc-max",
    ["spc-max"] = "spc-max",
    ["minimal"] = "spc-min",
    ["spc-min"] = "spc-min",
}

local UNIX_FLAVOR_ALIASES = {
    ["bulk"] = "bulk",
    ["common"] = "common",
    ["gnu-bulk"] = "gnu-bulk",
    ["minimal"] = "minimal",
    ["spc-max"] = "bulk",
    ["spc-min"] = "minimal",
}

local PATH_SEP = package.config:sub(1, 1)

local function join_path(...)
    return table.concat({ ... }, PATH_SEP)
end

local function is_windows()
    return RUNTIME.osType == "windows"
end

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
    return RUNTIME.osType == "linux" or RUNTIME.osType == "darwin" or RUNTIME.osType == "windows"
end

function M.normalize_flavor(value)
    if is_blank(value) then
        return M.DEFAULT_FLAVOR
    end

    value = tostring(value)
    if not FLAVORS[value] then
        error(
            "Unsupported prebuilt static PHP flavor: " .. value .. "\n" ..
            "Supported flavors: bulk, common, gnu-bulk, minimal, spc-max, spc-min"
        )
    end

    return value
end

function M.resolve_flavor(value)
    local flavor = M.normalize_flavor(value)

    if is_windows() then
        local resolved = WINDOWS_FLAVOR_ALIASES[flavor]
        if resolved ~= nil then
            return resolved
        end

        error(
            "Unsupported prebuilt static PHP flavor for Windows: " .. flavor .. "\n" ..
            "Supported Windows flavors: bulk/spc-max, minimal/spc-min"
        )
    end

    return UNIX_FLAVOR_ALIASES[flavor]
end

function M.os_name()
    if RUNTIME.osType == "darwin" then
        return "macos"
    end

    if RUNTIME.osType == "linux" then
        return "linux"
    end

    if RUNTIME.osType == "windows" then
        return "win"
    end

    return nil
end

function M.arch_name()
    if is_windows() then
        return ""
    end

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

    if os_name == nil then
        error("Prebuilt static PHP is only available on supported Linux, macOS, and Windows platforms.")
    end

    if is_windows() then
        return "php-" .. version .. "-" .. M.DEFAULT_SAPI .. "-win.zip"
    end

    if arch_name == "" then
        error("Prebuilt static PHP is only available on supported Linux and macOS architectures.")
    end

    return "php-" .. version .. "-" .. M.DEFAULT_SAPI .. "-" .. os_name .. "-" .. arch_name .. ".tar.gz"
end

function M.release_path(flavor)
    flavor = M.resolve_flavor(flavor)

    if is_windows() then
        return "windows/" .. flavor
    end

    return flavor
end

function M.asset_url(version, flavor)
    return M.BASE_URL .. "/" .. M.release_path(flavor) .. "/" .. M.asset_name(version, flavor)
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
    local os_name = M.os_name()
    local arch_name = M.arch_name()

    if os_name == nil or (not is_windows() and arch_name == "") then
        return {}
    end

    local resp, err = http.get({
        url = M.BASE_URL .. "/" .. M.release_path(flavor) .. "/",
        headers = {
            ["User-Agent"] = "verzly-mise-php",
        },
    })

    if err ~= nil or resp.status_code ~= 200 then
        error("Failed to fetch static-php-cli prebuilt binaries: " .. tostring(err))
    end

    local versions = {}
    local seen = {}
    local pattern

    if is_windows() then
        pattern = "php%-([0-9][0-9A-Za-z%.%-]*)%-" .. M.DEFAULT_SAPI .. "%-win%.zip"
    else
        pattern = "php%-([0-9][0-9A-Za-z%.%-]*)%-" .. M.DEFAULT_SAPI .. "%-" .. os_name .. "%-" .. arch_name .. "%.tar%.gz"
    end

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
    local requested = M.normalize_flavor(flavor)
    local resolved = M.resolve_flavor(flavor)
    local flavor_label = requested

    if requested ~= resolved then
        flavor_label = requested .. " -> " .. resolved
    end

    return "\27[93mWarning:\27[0m " ..
        "Using static-php-cli prebuilt PHP binaries (" .. flavor_label .. "). " ..
        "Fewer PHP versions may be available than source builds, and new PHP versions may appear later."
end

local function find_prebuilt_php_binary(sdkPath)
    local binary_name = is_windows() and "php.exe" or "php"
    local candidates

    if is_windows() then
        candidates = {
            join_path(sdkPath, "php.exe"),
            join_path(sdkPath, "bin", "php.exe"),
            join_path(sdkPath, "buildroot", "bin", "php.exe"),
        }
    else
        candidates = {
            join_path(sdkPath, "bin", "php"),
            join_path(sdkPath, "php"),
            join_path(sdkPath, "buildroot", "bin", "php"),
        }
    end

    for _, candidate in ipairs(candidates) do
        local f = io.open(candidate, "r")
        if f then
            f:close()
            return candidate
        end
    end

    local result_file = os.tmpname()
    os.remove(result_file)

    if is_windows() then
        local cmd = string.format(
            'powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path \'%s\' -Recurse -File -Filter %s | Select-Object -First 1 -ExpandProperty FullName" > "%s" 2>NUL',
            sdkPath,
            binary_name,
            result_file
        )
        os.execute(cmd)
    else
        os.execute("find '" .. sdkPath .. "' -type f -name php 2>/dev/null | head -n 1 > '" .. result_file .. "'")
    end

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

local function copy_binary(source, destination)
    if source == destination then
        return true
    end

    local cmd
    if is_windows() then
        cmd = string.format('cmd /c copy /Y "%s" "%s" > NUL', source, destination)
    else
        cmd = string.format("cp '%s' '%s'", source, destination)
    end

    local status = os.execute(cmd)
    return status == 0 or status == true
end

function M.install(sdkPath, version)
    local tools = require("lib/tools")

    print("Preparing prebuilt static PHP...")

    local major, minor = version:match("^(%d+)%.(%d+)")
    major, minor = tonumber(major) or 0, tonumber(minor) or 0

    if is_windows() then
        os.execute(string.format('mkdir "%s" 2>NUL', sdkPath))
    else
        os.execute(string.format("mkdir -p '%s/bin' '%s/conf.d'", sdkPath, sdkPath))
    end

    local php_bin = is_windows() and join_path(sdkPath, "php.exe") or join_path(sdkPath, "bin", "php")
    local php_exists = io.open(php_bin, "r")

    if php_exists then
        php_exists:close()
    else
        local candidate = find_prebuilt_php_binary(sdkPath)
        if not candidate then
            error(
                "\n\nFailed to prepare prebuilt static PHP.\n\n" ..
                "The downloaded static-php-cli archive did not contain a PHP CLI binary.\n" ..
                "Flavor: \27[93m" .. M.resolve_flavor(PREBUILT_STATIC_FLAVOR) .. "\27[0m\n" ..
                "Version: \27[93m" .. version .. "\27[0m\n"
            )
        end

        if not copy_binary(candidate, php_bin) then
            error(
                "\n\nFailed to prepare prebuilt static PHP.\n\n" ..
                "Could not copy the PHP binary into the expected installation directory.\n"
            )
        end
    end

    if not is_windows() then
        local chmod_status = os.execute('chmod +x "' .. php_bin .. '"' .. QUIET)
        if chmod_status ~= 0 and chmod_status ~= true then
            error(
                "\n\nFailed to prepare prebuilt static PHP.\n\n" ..
                "Could not make the PHP binary executable.\n"
            )
        end

        local confFile = io.open(join_path(sdkPath, "conf.d", "php.ini"), "w")
        if confFile then
            confFile:write("# Add system-wide PHP configuration options here\n")
            confFile:close()
        end
    end

    local status
    if is_windows() then
        status = os.execute('"' .. php_bin .. '" --version > NUL 2>&1')
    else
        status = os.execute('"' .. php_bin .. '" --version > /dev/null 2>&1')
    end

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
