local env = require("lib/env")
local messages = require("lib/messages")
local php_versions = require("lib/php_versions")
local tools = require("lib/tools")

local M = {}

local QUIET = env.QUIET

M.DEFAULT_FLAVOR = "bulk"
M.DEFAULT_SAPI = "cli"
-- Sources are checked in order; the first matching artifact wins.
local SOURCES = {
    { url = "https://dl.static-php.dev/v3/php-bin", windows_prefix = "" },
    { url = "https://dl.static-php.dev/static-php-cli", windows_prefix = "windows/" },
}
local artifact_urls = {}

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

local join_path = tools.join_path
local is_windows = tools.is_windows

local function is_blank(value)
    return value == nil or value == "" or value == false
end

function M.is_supported_platform()
    return RUNTIME.osType == "linux" or RUNTIME.osType == "darwin" or RUNTIME.osType == "windows"
end

function M.is_requested(ctx)
    return env.resolve(ctx).PREBUILT_STATIC
end

function M.requested_flavor(ctx)
    return env.resolve(ctx).PREBUILT_STATIC_FLAVOR
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
    local asset = M.asset_name(version, flavor)
    local key = M.resolve_flavor(flavor)
    if artifact_urls[key] and artifact_urls[key][asset] then
        return artifact_urls[key][asset]
    end
    local source = SOURCES[#SOURCES]
    local path = (is_windows() and source.windows_prefix or "") .. key
    return source.url .. "/" .. path .. "/" .. asset
end

function M.available_versions(http, flavor, ctx)
    local os_name = M.os_name()
    local arch_name = M.arch_name()

    if os_name == nil or (not is_windows() and arch_name == "") then
        return {}
    end

    local versions = {}
    local seen = {}
    local resolved_urls = {}
    local pattern

    if is_windows() then
        pattern = "php%-([0-9][0-9A-Za-z%.%-]*)%-" .. M.DEFAULT_SAPI .. "%-win%.zip"
    else
        pattern = "php%-([0-9][0-9A-Za-z%.%-]*)%-" .. M.DEFAULT_SAPI .. "%-" .. os_name .. "%-" .. arch_name .. "%.tar%.gz"
    end

    local resolved_flavor = M.resolve_flavor(flavor)
    local function fetch_versions(source)
        local path = (is_windows() and source.windows_prefix or "") .. resolved_flavor
        local url = source.url .. "/" .. path .. "/"
        local resp, err = http.get({
            url = url,
            headers = { ["User-Agent"] = "verzly-mise-php" },
        })
        if err ~= nil or resp == nil or resp.status_code ~= 200 then
            error("Failed to fetch static-php-cli prebuilt binaries: " .. tostring(err or (resp and resp.status_code)))
        end
        for href in (resp.body or ""):gmatch('[hH][rR][eE][fF]%s*=%s*["\']([^"\']+)["\']') do
            local asset = href:match("([^/]+)$")
            local version = asset and asset:match("^" .. pattern .. "$")
            if version then
                resolved_urls[asset] = resolved_urls[asset] or (source.url .. "/" .. path .. "/" .. asset)
            end
            if version and not seen[version] then
                seen[version] = true
                table.insert(versions, version)
            end
        end
    end

    for _, source in ipairs(SOURCES) do
        fetch_versions(source)
    end
    artifact_urls[resolved_flavor] = resolved_urls

    table.sort(versions, php_versions.greater_than)

    local all_versions = {}
    for _, version in ipairs(versions) do
        table.insert(all_versions, php_versions.available_record(version))
    end

    local result = php_versions.filter_for_available(all_versions, ctx)

    return php_versions.append_aliases(result, all_versions)
end

function M.release(version, flavor)
    return {
        version = version,
        url = M.asset_url(version, flavor),
    }
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
        if tools.file_exists(candidate) then
            return candidate
        end
    end

    if is_windows() then
        local ok, _, _, output = tools.execute_cmd(string.format(
            'dir /s /b "%s"',
            join_path(sdkPath, binary_name)
        ), '')

        if ok then
            for candidate in tostring(output):gmatch("[^\r\n]+") do
                if candidate ~= "" then
                    return candidate
                end
            end
        end

        return nil
    end

    local result_file = os.tmpname()
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

function M.install(sdkPath, version, config)
    print("Preparing prebuilt static PHP...")

    if is_windows() then
        os.execute(string.format('mkdir "%s" 2>NUL', sdkPath))
    else
        os.execute(string.format("mkdir -p '%s/bin' '%s/conf.d'", sdkPath, sdkPath))
    end

    local php_bin = is_windows() and join_path(sdkPath, "php.exe") or join_path(sdkPath, "bin", "php")
    if tools.file_exists(php_bin) then
        -- PHP is already in the expected location.
    else
        local candidate = find_prebuilt_php_binary(sdkPath)
        if not candidate then
            error(
                "\n\nFailed to prepare prebuilt static PHP.\n\n" ..
                "The downloaded static-php-cli archive did not contain a PHP CLI binary.\n" ..
                "Flavor: \27[93m" .. M.resolve_flavor(config.PREBUILT_STATIC_FLAVOR) .. "\27[0m\n" ..
                "Version: \27[93m" .. version .. "\27[0m\n"
            )
        end

        if not tools.copy_file(candidate, php_bin) then
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

        tools.write_file(join_path(sdkPath, "conf.d", "php.ini"), "# Add system-wide PHP configuration options here\n")
    end

    local status
    if is_windows() then
        status = tools.execute_cmd(string.format(
            '"%s" -version',
            php_bin
        ), QUIET)
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

    return {
        kind = "static",
    }
end


return M
