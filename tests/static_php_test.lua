local env = require("lib/env")
local php_versions = require("lib/php_versions")
local static_php = require("lib/static_php")
local tools = require("lib/tools")

local M = {}
local CURRENT = static_php.BASE_URL
local LEGACY = static_php.LEGACY_BASE_URL

local function equal(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function fails(fn, message)
    local ok, err = pcall(fn)
    assert(not ok, "expected failure: " .. message)
    assert(tostring(err):find(message, 1, true), tostring(err))
end

local function mock_http(expected)
    local calls = 0
    local function request(method, opts)
        calls = calls + 1
        local response = expected[calls]
        assert(response, "unexpected " .. method .. " " .. opts.url)
        equal(method, response[1])
        equal(opts.url, response[2])
        equal(opts.headers["User-Agent"], "verzly-mise-php")
        if response.raise then
            error(response.raise)
        end
        if response[3] == nil then
            return nil, response.err
        end
        return { status_code = response[3], body = response[4] or "" }, response.err
    end

    return {
        get = function(opts) return request("get", opts) end,
        head = function(opts) return request("head", opts) end,
    }, function()
        equal(calls, #expected)
    end
end

local function fixture(name)
    local f = assert(io.open(RUNTIME.pluginDirPath .. "/tests/fixtures/static_php/" .. name .. ".html", "r"))
    local body = f:read("*a")
    f:close()
    return body
end

local function version_list(records)
    local result = {}
    for _, record in ipairs(records) do
        if not php_versions.is_alias(record.version) then
            table.insert(result, record.version)
        end
    end
    return table.concat(result, ",")
end

function M.run(available)
    local count = 0
    local function test(name, fn)
        local ok, err = pcall(fn)
        assert(ok, name .. ": " .. tostring(err))
        count = count + 1
    end

    local original_runtime = RUNTIME
    RUNTIME = {
        osType = original_runtime.osType,
        archType = original_runtime.archType,
        version = original_runtime.version,
        pluginDirPath = original_runtime.pluginDirPath,
    }
    local function platform(os_type, arch)
        RUNTIME.osType = os_type
        RUNTIME.archType = arch
    end

    -- Avoid inspecting the mise command line; exercise ctx flags deterministically.
    php_versions.prerelease_flag_enabled = function(ctx)
        return ctx ~= nil and ctx.prerelease == true
    end

    platform("darwin", "arm64")
    local current_body, legacy_body = fixture("current"), fixture("legacy")

    test("merge, deduplicate, filter and sort both feeds", function()
        local http, done = mock_http({
            { "get", CURRENT .. "/bulk/", 200, current_body },
            { "get", LEGACY .. "/bulk/", 200, legacy_body },
        })
        local records = static_php.available_versions(http, nil, {})
        equal(version_list(records), "8.5.12,8.5.9,8.5.8,8.5.5,8.0.30")
        equal(records[1].version, "prerelease")
        equal(records[2].version, "latest")
        equal(records[3].version, "stable")
        done()
    end)

    for _, ctx in ipairs({ { prerelease = true }, { version = "latest" }, { version = "8.6.0RC1" } }) do
        test("preserve prerelease requests: " .. tostring(ctx.version or "flag"), function()
            local http, done = mock_http({
                { "get", CURRENT .. "/bulk/", 200, current_body },
                { "get", LEGACY .. "/bulk/", 200, legacy_body },
            })
            equal(version_list(static_php.available_versions(http, "bulk", ctx)),
                "8.6.0RC1,8.5.12,8.5.9,8.5.8,8.5.5,8.0.30")
            done()
        end)
    end

    for _, version in ipairs({ "8.5.12", "8.5.8" }) do
        test("prefer current for current-only or duplicate " .. version, function()
            local url = static_php.asset_url(version, "bulk")
            local http, done = mock_http({ { "head", url, 200 } })
            local release = static_php.release(version, "bulk", http)
            equal(release.version, version)
            equal(release.url, url)
            done()
        end)
    end

    test("fall back to the exact legacy artifact", function()
        local current = static_php.asset_url("8.0.30", "bulk")
        local legacy = static_php.asset_url("8.0.30", "bulk", LEGACY)
        local http, done = mock_http({ { "head", current, 404 }, { "head", legacy, 200 } })
        local release = static_php.release("8.0.30", "bulk", http)
        equal(release.version, "8.0.30")
        equal(release.url, legacy)
        done()
    end)

    test("both exact artifacts missing", function()
        local current = static_php.asset_url("8.5.12", "bulk")
        local legacy = static_php.asset_url("8.5.12", "bulk", LEGACY)
        local http, done = mock_http({ { "head", current, 404 }, { "head", legacy, 404 } })
        fails(function() static_php.release("8.5.12", "bulk", http) end, "artifact not found")
        done()
    end)

    for _, missing in ipairs({ CURRENT, LEGACY }) do
        test("missing directory: " .. missing, function()
            local http, done = mock_http({
                { "get", CURRENT .. "/bulk/", missing == CURRENT and 404 or 200, current_body },
                { "get", LEGACY .. "/bulk/", missing == LEGACY and 404 or 200, legacy_body },
            })
            equal(version_list(static_php.available_versions(http, "bulk", {})),
                missing == CURRENT and "8.5.8,8.5.5,8.0.30" or "8.5.12,8.5.9,8.5.8")
            done()
        end)
    end

    test("both missing directories return no versions", function()
        local http, done = mock_http({
            { "get", CURRENT .. "/bulk/", 404 },
            { "get", LEGACY .. "/bulk/", 404 },
        })
        equal(#static_php.available_versions(http, "bulk", {}), 0)
        done()
    end)

    for _, method in ipairs({ "get", "head" }) do
        for _, root in ipairs({ CURRENT, LEGACY }) do
            for _, status in ipairs({ 401, 403, 405, 408, 410, 429, 500, 503 }) do
                test(method .. " fails on HTTP " .. status .. " from " .. root, function()
                    local expected = {}
                    local function url(base)
                        return method == "get" and base .. "/bulk/" or static_php.asset_url("8.5.12", "bulk", base)
                    end
                    if root == LEGACY then
                        table.insert(expected, { method, url(CURRENT), method == "get" and 200 or 404, current_body })
                    end
                    table.insert(expected, { method, url(root), status })
                    local http, done = mock_http(expected)
                    fails(function()
                        if method == "get" then
                            static_php.available_versions(http, "bulk", {})
                        else
                            static_php.release("8.5.12", "bulk", http)
                        end
                    end, url(root) .. ": HTTP " .. status)
                    done()
                end)
            end

            for _, failure in ipairs({ { err = "TLS failure" }, { raise = "connection timeout" }, {} }) do
                test(method .. " propagates transport/nil failures from " .. root, function()
                    local suffix = method == "get" and "/bulk/" or "/bulk/php-8.5.12-cli-macos-aarch64.tar.gz"
                    local expected = {}
                    if root == LEGACY then
                        table.insert(expected, { method, CURRENT .. suffix, method == "get" and 200 or 404, current_body })
                    end
                    table.insert(expected, { method, root .. suffix, err = failure.err, raise = failure.raise })
                    local http, done = mock_http(expected)
                    fails(function()
                        if method == "get" then
                            static_php.available_versions(http, "bulk", {})
                        else
                            static_php.release("8.5.12", "bulk", http)
                        end
                    end, failure.err or failure.raise or "HTTP nil")
                    done()
                end)
            end
        end
    end

    local unix_flavors = {
        bulk = "bulk", common = "common", ["gnu-bulk"] = "gnu-bulk", minimal = "minimal",
        ["spc-max"] = "bulk", ["spc-min"] = "minimal",
    }
    for _, os_type in ipairs({ "linux", "darwin" }) do
        for _, arch in ipairs({ "amd64", "x64", "x86_64", "arm64", "aarch64" }) do
            for _, flavor in ipairs({ "bulk", "common", "gnu-bulk", "minimal", "spc-max", "spc-min" }) do
                test(os_type .. "/" .. arch .. "/" .. flavor, function()
                    platform(os_type, arch)
                    local resolved = unix_flavors[flavor]
                    equal(static_php.resolve_flavor(flavor), resolved)
                    local os_name = os_type == "darwin" and "macos" or "linux"
                    local arch_name = (arch == "arm64" or arch == "aarch64") and "aarch64" or "x86_64"
                    local filename = "php-8.5.12-cli-" .. os_name .. "-" .. arch_name .. ".tar.gz"
                    equal(static_php.asset_name("8.5.12", flavor), filename)
                    local http, done = mock_http({
                        { "get", CURRENT .. "/" .. resolved .. "/", 200, filename },
                        { "get", LEGACY .. "/" .. resolved .. "/", 200, "php-8.5.13-cli-win.zip" },
                    })
                    equal(version_list(static_php.available_versions(http, flavor, {})), "8.5.12")
                    done()
                end)
            end
        end
    end

    test("macOS GNU flavor does not expose Linux artifacts", function()
        platform("darwin", "arm64")
        local http, done = mock_http({
            { "get", CURRENT .. "/gnu-bulk/", 200, "php-8.5.12-cli-linux-aarch64.tar.gz" },
            { "get", LEGACY .. "/gnu-bulk/", 200, "php-8.5.8-cli-linux-aarch64.tar.gz" },
        })
        equal(#static_php.available_versions(http, "gnu-bulk", {}), 0)
        done()
    end)

    for _, flavor in ipairs({ "bulk", "minimal", "spc-max", "spc-min" }) do
        test("Windows paths and fallback: " .. flavor, function()
            platform("windows", "amd64")
            local resolved = (flavor == "bulk" or flavor == "spc-max") and "spc-max" or "spc-min"
            local current_dir = CURRENT .. "/" .. resolved .. "/"
            local legacy_dir = LEGACY .. "/windows/" .. resolved .. "/"
            local filename = "php-8.5.12-cli-win.zip"
            equal(static_php.asset_name("8.5.12", flavor), filename)
            local http, done = mock_http({
                { "get", current_dir, 200, filename .. " php-8.5.13-micro-win.zip" },
                { "get", legacy_dir, 200, "php-8.0.30-cli-win.zip" },
                { "head", current_dir .. filename, 200 },
                { "head", current_dir .. filename, 404 },
                { "head", legacy_dir .. filename, 200 },
            })
            equal(version_list(static_php.available_versions(http, flavor, {})), "8.5.12,8.0.30")
            equal(static_php.release("8.5.12", flavor, http).url, current_dir .. filename)
            equal(static_php.release("8.5.12", flavor, http).url, legacy_dir .. filename)
            done()
        end)
    end

    test("reject unsupported flavors before HTTP", function()
        platform("windows", "amd64")
        local http, done = mock_http({})
        for _, flavor in ipairs({ "common", "gnu-bulk", "unknown" }) do
            fails(function() static_php.available_versions(http, flavor, {}) end, "Unsupported prebuilt static PHP flavor")
        end
        done()
    end)

    test("unsupported platforms remain empty", function()
        local http, done = mock_http({})
        platform("freebsd", "amd64")
        equal(#static_php.available_versions(http, "bulk", {}), 0)
        platform("linux", "")
        equal(#static_php.available_versions(http, "bulk", {}), 0)
        done()
    end)

    for _, requested in ipairs({ "8", "8.5", "stable", "latest", "prerelease", "8.6.0RC1" }) do
        test("static hook resolves " .. requested, function()
            platform("darwin", "arm64")
            env.PREBUILT_STATIC = true
            local version = (requested == "8" or requested == "8.5" or requested == "stable") and "8.5.12" or "8.6.0RC1"
            local url = CURRENT .. "/bulk/php-" .. version .. "-cli-macos-aarch64.tar.gz"
            local http, done = mock_http({
                { "get", CURRENT .. "/bulk/", 200, current_body },
                { "get", LEGACY .. "/bulk/", 200, legacy_body },
                { "head", url, 200 },
            })
            package.loaded["http"] = http
            local plugin = { Available = available, PreInstall = PLUGIN.PreInstall }
            local release = plugin:PreInstall({ version = requested })
            equal(release.version, version)
            equal(release.url, url)
            done()
        end)
    end

    test("hooks resolve once and never substitute an older exact patch", function()
        platform("darwin", "arm64")
        env.PREBUILT_STATIC = false
        local opts = { prebuilt_static = "true", prebuilt_static_flavor = "minimal" }
        local url = CURRENT .. "/minimal/php-8.5.12-cli-macos-aarch64.tar.gz"
        local http, done = mock_http({
            { "get", CURRENT .. "/minimal/", 200, current_body },
            { "get", LEGACY .. "/minimal/", 200, legacy_body },
            { "head", url, 404 },
            { "head", LEGACY .. "/minimal/php-8.5.12-cli-macos-aarch64.tar.gz", 404 },
        })
        package.loaded["http"] = http
        local plugin = { Available = available, PreInstall = PLUGIN.PreInstall }
        fails(function() plugin:PreInstall({ version = "8.5.12", options = opts }) end, "artifact not found")
        done()

        http, done = mock_http({
            { "get", CURRENT .. "/minimal/", 200, current_body },
            { "get", LEGACY .. "/minimal/", 200, legacy_body },
        })
        package.loaded["http"] = http
        fails(function() plugin:PreInstall({ version = "8.5.11", options = opts }) end, "Version not found: 8.5.11")
        done()
    end)

    test("source and default Windows hooks never query StaticPHP", function()
        env.PREBUILT_STATIC = false
        local dependencies = {}
        version_check_before_dependencies = function() table.insert(dependencies, "before") end
        install_dependencies = function() table.insert(dependencies, "install") end
        version_check_after_dependencies = function() table.insert(dependencies, "after") end
        local plugin = { Available = available, PreInstall = PLUGIN.PreInstall }
        local source_url = "https://raw.githubusercontent.com/verzly/mise-php/cache/versions.txt"
        local http, done = mock_http({
            { "get", source_url, 200, "8.5.12\n8.0.30\n" },
            { "get", source_url, 200, "8.5.12\n8.0.30\n" },
        })
        package.loaded["http"] = http
        platform("linux", "amd64")
        local release = plugin:PreInstall({ version = "8.0.30", options = { prebuilt_static = "false" } })
        equal(release.version, "8.0.30")
        equal(release.url, "https://github.com/php/php-src/archive/php-8.0.30.tar.gz")
        equal(table.concat(dependencies, ","), "before,install,after")
        platform("windows", "amd64")
        release = plugin:PreInstall({ version = "8.5.12" })
        equal(release.version, "8.5.12")
        equal(release.url, nil)
        equal(#dependencies, 3)
        done()
    end)

    test("static runtime validation failures remain fatal", function()
        platform("darwin", "arm64")
        local original_execute, original_exists, original_write = os.execute, tools.file_exists, tools.write_file
        os.execute = function(command)
            return command:find("--version", 1, true) and 1 or 0
        end
        tools.file_exists = function() return true end
        tools.write_file = function() return true end
        fails(function() static_php.install("unused-test-sdk", "8.5.12") end, "'php --version' failed")
        os.execute, tools.file_exists, tools.write_file = original_execute, original_exists, original_write
    end)

    test("missing Windows executable remains fatal", function()
        platform("windows", "amd64")
        local original_execute, original_exists, original_cmd = os.execute, tools.file_exists, tools.execute_cmd
        os.execute = function() return 0 end
        tools.file_exists = function() return false end
        tools.execute_cmd = function() return false end
        fails(function() static_php.install("unused-test-sdk", "8.5.12") end, "did not contain a PHP CLI binary")
        os.execute, tools.file_exists, tools.execute_cmd = original_execute, original_exists, original_cmd
    end)

    RUNTIME = original_runtime
    print("Passed " .. count .. " StaticPHP regression tests (mocked HTTP; no binary downloads).")
end

return M
