local env = require("lib/env")
local archiver = require("archiver")
local messages = require("lib/messages")
local tools = require("lib/tools")

local QUIET           = env.QUIET

local M = {}

local join_path = tools.join_path
local file_exists = tools.file_exists
local read_file = tools.read_file
local write_file = tools.write_file

local function normalize_arch()
    local arch = string.lower(RUNTIME.archType or "")

    if arch == "x86" or arch == "i386" or arch == "i686" or arch == "386" then
        return "x86"
    end

    -- Official PHP for Windows publishes x64/x86 packages. On 64-bit Windows,
    -- including ARM64 Windows running x64 emulation, x64 is the safest default.
    return "x64"
end

local function vs_version(version)
    local major_minor = version:match("^(%d+%.%d+)")
    local map = {
        ["5.2"] = "VC6",
        ["5.3"] = "VC9",
        ["5.4"] = "VC9",
        ["5.5"] = "VC11",
        ["5.6"] = "VC11",
        ["7.0"] = "VC14",
        ["7.1"] = "VC14",
        ["7.2"] = "VC15",
        ["7.3"] = "VC15",
        ["7.4"] = "vc15",
        ["8.0"] = "vs16",
        ["8.1"] = "vs16",
        ["8.2"] = "vs16",
        ["8.3"] = "vs16",
        ["8.4"] = "vs17",
        ["8.5"] = "vs17",
    }

    local resolved = map[major_minor]
    if resolved then
        return resolved
    end

    error("Unsupported PHP version: " .. version .. " (resolved major.minor: " .. tostring(major_minor) .. ")")
end

local function php_zip_name(version, arch)
    return string.format(
        "php-%s-nts-Win32-%s-%s.zip",
        version,
        vs_version(version),
        arch
    )
end

local function php_urls(version, arch)
    local zip_name = php_zip_name(version, arch)
    return {
        "https://windows.php.net/downloads/releases/" .. zip_name,
        "https://windows.php.net/downloads/releases/archives/" .. zip_name,
        "https://windows.php.net/downloads/qa/" .. zip_name,
        "https://downloads.php.net/~windows/releases/" .. zip_name,
        "https://downloads.php.net/~windows/releases/archives/" .. zip_name,
        "https://downloads.php.net/~windows/qa/" .. zip_name,
    }
end

local function download_first_available(urls, destination)
    local last_error = nil

    for _, url in ipairs(urls) do
        print("Trying: " .. url)

        local ok, err = tools.download_file(url, destination)

        if ok then
            print("Downloaded from: " .. url)
            return true
        end

        last_error = err or "download did not create the expected file"
        os.remove(destination)
    end

    return false, last_error
end

local function set_contains(lines, value)
    value = string.lower(value)
    for line in tostring(lines):gmatch("[^\r\n]+") do
        if string.lower(line:gsub("^%s+", ""):gsub("%s+$", "")) == value then
            return true
        end
    end

    return false
end

local function normalize_extension_name(extension)
    extension = tostring(extension):gsub("^%s+", ""):gsub("%s+$", "")
    extension = extension:gsub("%.dll$", "")
    extension = extension:gsub("^php_", "")

    return extension
end

local function list_configurable_extensions(php_ini_content, ext_dir)
    local result = {}
    local seen = {}
    local already_enabled = {}

    for line in tostring(php_ini_content):gmatch("[^\r\n]+") do
        local active_extension = line:match('^%s*extension%s*=%s*([^;%s]+)%s*;?.*$')
        if active_extension then
            already_enabled[normalize_extension_name(active_extension):lower()] = true
        end
    end

    for line in tostring(php_ini_content):gmatch("[^\r\n]+") do
        local extension = line:match('^%s*;extension%s*=%s*([^;%s]+)%s*;?.*$')
        if extension then
            local name = normalize_extension_name(extension)
            local key = name:lower()
            if not seen[key] and not already_enabled[key] and file_exists(join_path(ext_dir, "php_" .. name .. ".dll")) then
                seen[key] = true
                result[#result + 1] = name
            end
        end
    end

    table.sort(result)
    return result
end

local function rewrite_php_ini_line(line, ext_dir, timezone, enabled_extensions, enabled_zend_extensions)
    if line:match('^%s*extension_dir%s*=') or line:match('^%s*;%s*extension_dir%s*=') then
        return 'extension_dir = "' .. ext_dir .. '"'
    end

    if line:match('^%s*;%s*date%.timezone%s*=') then
        return 'date.timezone = "' .. timezone .. '"'
    end

    local extension = line:match('^%s*;extension%s*=%s*([^;%s]+)%s*;?.*$')
    if extension and enabled_extensions[extension:lower()] then
        return 'extension=' .. extension
    end

    local zend_extension = line:match('^%s*;zend_extension%s*=%s*([^;%s]+)%s*;?.*$')
    if zend_extension and enabled_zend_extensions[zend_extension:lower()] then
        return 'zend_extension=' .. zend_extension
    end

    return line
end

local function rewrite_php_ini(content, ext_dir, timezone, enabled_extensions, enabled_zend_extensions)
    local lines = {}
    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")

    for line in (content .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = rewrite_php_ini_line(
            line,
            ext_dir,
            timezone,
            enabled_extensions,
            enabled_zend_extensions
        )
    end

    return table.concat(lines, "\r\n")
end

local function configure_php_ini(sdk_path, timezone)
    local php_ini_source = join_path(sdk_path, "php.ini-production")
    if not file_exists(php_ini_source) then
        php_ini_source = join_path(sdk_path, "php.ini-recommended")
    end

    if not file_exists(php_ini_source) then
        return
    end

    local php_bin = join_path(sdk_path, "php.exe")
    local ext_dir = join_path(sdk_path, "ext")
    local content = read_file(php_ini_source)
    if content == nil then
        return
    end

    local php_modules = ""

    -- Verify PIE installation
    local ok, _, _, output = tools.execute_cmd(string.format(
        '"%s" -m',
        php_bin
    ), '')

    if ok then
        php_modules = tostring(output)
    end

    local blacklist = {
        pdo_firebird = true,
        snmp = true,
    }
    local enabled_extensions = {}

    local extension_dlls = list_configurable_extensions(content, ext_dir)

    for _, extension in ipairs(extension_dlls) do
        local name = extension:lower()
        if blacklist[name] then
            print("Skipping " .. extension .. " - requires external dependencies")
        elseif set_contains(php_modules, name) then
            print("Skipping " .. extension .. " - already compiled statically")
        else
            enabled_extensions[name] = true
            print("Enabled " .. extension)
        end
    end

    local enabled_zend_extensions = {}
    if file_exists(join_path(ext_dir, "php_opcache.dll")) and not set_contains(php_modules, "opcache") then
        enabled_zend_extensions.opcache = true
    end

    if not write_file(
        join_path(sdk_path, "php.ini"),
        rewrite_php_ini(content, ext_dir, timezone, enabled_extensions, enabled_zend_extensions)
    ) then
        error("Failed to write php.ini")
    end
end

function M.install(sdkPath, version)
    print("Installing PHP...")

    local arch = normalize_arch()
    local archive_path = join_path(sdkPath, "php-" .. version .. "-windows.zip")

    print("Downloading PHP " .. version .. " (" .. arch .. ", nts) -> " .. sdkPath)

    local ok, err = download_first_available(php_urls(version, arch), archive_path)
    if not ok then
        error(
            "\n\nFailed to download PHP " .. version .. ".\n" ..
            "Last error: " .. tostring(err or "unknown error") .. "\n\n" ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end

    local extract_err = archiver.decompress(archive_path, sdkPath)
    os.remove(archive_path)

    if extract_err ~= nil then
        error(
            "\n\nFailed to extract PHP " .. version .. ".\n" ..
            tostring(extract_err) .. "\n\n" ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end

    configure_php_ini(sdkPath, "UTC")

    local php_bin = join_path(sdkPath, "php.exe")
    local ok = tools.execute_cmd(string.format(
        '"%s" -version',
        php_bin
    ), QUIET)

    if not ok then
        error(
            "\n\nPHP installation appears to be broken: 'php --version' failed.\n\n" ..
            messages.verbose_tip(version) ..
            messages.see("debugging")
        )
    end

    print("PHP installation complete!")

    return {
        kind = "windows",
    }
end

return M
