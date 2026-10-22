package.path = "./?.lua;./?/init.lua;" .. package.path
local original_plugin_dir = STATIC_TEST_PLUGIN_DIR

package.preload["lib/env"] = function() return { QUIET = "", PREBUILT_STATIC_FLAVOR = "bulk" } end
package.preload["lib/messages"] = function() return {} end
package.preload["lib/options"] = function() return { enabled = function(v) return v == true end, get = function(ctx, key) return ctx[key] end } end
package.preload["lib/tools"] = function()
    return { join_path = function(...) return table.concat({ ... }, "/") end, is_windows = function() return RUNTIME.osType == "windows" end }
end

local function equal(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function includes(records, version)
    for _, record in ipairs(records) do if record.version == version then return true end end
    return false
end

local function actual_versions(records)
    local result = {}
    for _, record in ipairs(records) do
        if record.version:match("^%d") then result[#result + 1] = record.version end
    end
    return result
end

local M = require("lib/static_php")
local function hrefs(names)
    local html = ""
    for _, name in ipairs(names) do html = html .. '<a href="' .. name .. '">' .. name .. "</a>" end
    return html
end

local function discover(platform, arch, flavor, feeds, fail)
    RUNTIME = { osType = platform, archType = arch }
    local original_popen = io.popen
    if platform == "windows" then
        io.popen = function()
            return { read = function() return "" end, close = function() return true end }
        end
    end
    local calls = {}
    local http = { get = function(request)
        calls[#calls + 1] = request.url
        local index = #calls
        if fail and index == fail.index then
            if fail.nil_response then return nil, fail.error end
            if fail.nil_without_error then return nil end
            return { status_code = fail.status, body = "failure" }, fail.error
        end
        local feed = feeds[index]
        return { status_code = 200, body = hrefs(feed) }
    end }
    local ok, result = pcall(M.available_versions, http, flavor, {})
    io.popen = original_popen
    return ok, result, calls
end

RUNTIME = { osType = "linux", archType = "x64" }
local linux = function(v) return "php-" .. v .. "-cli-linux-x86_64.tar.gz" end
local ok, versions, calls = discover("linux", "x64", "bulk", {
    { linux("8.5.12") .. ".sha256", linux("8.5.13") .. ".sha256" },
    { linux("8.5.5"), linux("8.5.12") },
})
assert(ok)
local actual = actual_versions(versions)
equal(#actual, 2, "deduplicated merged versions")
equal(actual[1], "8.5.12", "numeric sort newest")
equal(actual[2], "8.5.5", "legacy version retained")
assert(not includes(versions, "8.5.13"), "checksum-only version must be excluded")
equal(calls[1], "https://dl.static-php.dev/v3/php-bin/bulk/", "current listing URL")
equal(calls[2], "https://dl.static-php.dev/static-php-cli/bulk/", "legacy listing URL")
equal(M.asset_url("8.5.12", "bulk"), "https://dl.static-php.dev/static-php-cli/bulk/" .. linux("8.5.12"), "legacy used when current has checksum only")
equal(M.asset_url("8.5.5", "bulk"), "https://dl.static-php.dev/static-php-cli/bulk/" .. linux("8.5.5"), "legacy-only URL")

ok, versions = discover("linux", "x64", "bulk", {
    { linux("8.5.12") },
    { linux("8.5.12"), linux("8.5.5") },
})
assert(ok)
equal(#actual_versions(versions), 2, "duplicate artifact appears once")
equal(M.asset_url("8.5.12", "bulk"), "https://dl.static-php.dev/v3/php-bin/bulk/" .. linux("8.5.12"), "first source wins duplicate")

ok = discover("linux", "x64", "bulk", { {}, { linux("8.5.12") } })
assert(ok)
equal(M.asset_url("8.5.12", "bulk"), "https://dl.static-php.dev/static-php-cli/bulk/" .. linux("8.5.12"), "fresh membership")

for _, failure in ipairs({
    { index = 1, status = 404 }, { index = 1, status = 500 }, { index = 1, nil_response = true, error = "transport" },
    { index = 1, nil_without_error = true }, { index = 1, status = 200, error = "transport" },
    { index = 2, status = 404 }, { index = 2, status = 500 }, { index = 2, nil_response = true, error = "transport" },
    { index = 2, nil_without_error = true }, { index = 2, status = 200, error = "transport" },
}) do
    ok = discover("linux", "x64", "bulk", { { linux("8.5.12") }, { linux("8.5.5") } }, failure)
    assert(not ok, "listing failure must propagate")
end

-- A failed second listing must not publish a partially refreshed URL map.
ok = discover("linux", "x64", "bulk", { { linux("8.5.12") }, { linux("8.5.5") } })
assert(ok)
ok = discover("linux", "x64", "bulk", { {}, {} }, { index = 2, status = 500 })
assert(not ok)
equal(M.asset_url("8.5.12", "bulk"), "https://dl.static-php.dev/v3/php-bin/bulk/" .. linux("8.5.12"), "atomic publication")

local mac = function(v) return "php-" .. v .. "-cli-macos-aarch64.tar.gz" end
ok, versions = discover("darwin", "arm64", "common", { { mac("8.4.1") }, {} })
assert(ok and includes(versions, "8.4.1"))
equal(M.asset_url("8.4.1", "common"), "https://dl.static-php.dev/v3/php-bin/common/" .. mac("8.4.1"), "macOS artifact")

local win = function(v) return "php-" .. v .. "-cli-win.zip" end
ok, versions, calls = discover("windows", "x64", "bulk", { { win("8.5.12") .. ".sha256", win("8.5.13") .. ".sha256" }, { win("8.5.5"), win("8.5.12") } })
assert(ok and includes(versions, "8.5.12") and includes(versions, "8.5.5"))
assert(not includes(versions, "8.5.13"), "Windows checksum-only version must be excluded")
equal(calls[1], "https://dl.static-php.dev/v3/php-bin/spc-max/", "Windows current listing URL")
equal(calls[2], "https://dl.static-php.dev/static-php-cli/windows/spc-max/", "Windows legacy listing URL")
equal(M.asset_url("8.5.12", "bulk"), "https://dl.static-php.dev/static-php-cli/windows/spc-max/" .. win("8.5.12"), "Windows legacy fallback")
equal(M.asset_url("8.5.5", "bulk"), "https://dl.static-php.dev/static-php-cli/windows/spc-max/" .. win("8.5.5"), "Windows legacy path")
ok = discover("windows", "x64", "minimal", { { win("8.5.12") }, {} })
assert(ok)
equal(M.asset_url("8.5.12", "minimal"), "https://dl.static-php.dev/v3/php-bin/spc-min/" .. win("8.5.12"), "Windows spc-min alias")
ok = discover("windows", "x64", "spc-min", { { win("8.5.12") }, {} })
assert(ok)
equal(M.asset_url("8.5.12", "spc-min"), "https://dl.static-php.dev/v3/php-bin/spc-min/" .. win("8.5.12"), "Windows spc-min flavor")
ok = discover("windows", "x64", "spc-max", { { win("8.5.12") }, {} })
assert(ok)
equal(M.asset_url("8.5.12", "spc-max"), "https://dl.static-php.dev/v3/php-bin/spc-max/" .. win("8.5.12"), "Windows spc-max flavor")
local unsupported = pcall(M.available_versions, { get = function() error("unexpected request") end }, "common", {})
assert(not unsupported, "unsupported Windows flavor must fail")

RUNTIME = { osType = "linux", archType = "x64" }
local preinstall_http = { get = function(request)
    if request.url == "https://dl.static-php.dev/v3/php-bin/bulk/" then
        return { status_code = 200, body = hrefs({ linux("8.5.12") }) }
    end
    if request.url == "https://dl.static-php.dev/static-php-cli/bulk/" then
        return { status_code = 200, body = hrefs({ linux("8.5.5") }) }
    end
    error("unexpected listing URL: " .. request.url)
end }
package.loaded["http"] = preinstall_http
require("lib/env").PREBUILT_STATIC = true
PLUGIN = {}
local available = dofile(original_plugin_dir .. "/lib/test_available.lua")
dofile(original_plugin_dir .. "/hooks/pre_install.lua")
local preinstalled = PLUGIN:PreInstall({
    version = "8.5.12",
    prebuilt_static = true,
    prebuilt_static_flavor = "bulk",
})
equal(preinstalled.url, "https://dl.static-php.dev/v3/php-bin/bulk/" .. linux("8.5.12"), "Available to PreInstall URL")
local exact_ok, exact_error = pcall(PLUGIN.PreInstall, PLUGIN, {
    version = "8.5.11",
    prebuilt_static = true,
    prebuilt_static_flavor = "bulk",
})
assert(not exact_ok and tostring(exact_error):find("Version not found: 8.5.11", 1, true), "missing patch must not resolve to older version")

print("static PHP discovery regression checks passed")
