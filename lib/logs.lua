local tools = require("lib/tools")

local logs = {}

function logs.sanitize_part(value)
    return tostring(value):gsub("[^%w%._%-]", "-")
end

function logs.utc_timestamp()
    return os.date("!%Y%m%dT%H%M%SZ")
end

function logs.temp_dir()
    if RUNTIME.osType == "windows" then
        return os.getenv("TEMP") or os.getenv("TMP") or "."
    end

    return os.getenv("TMPDIR") or "/tmp"
end

function logs.create_id(version)
    return logs.sanitize_part(version) .. "-" .. logs.utc_timestamp()
end

function logs.path(log_id, phase)
    return tools.join_path(
        logs.temp_dir(),
        "mise-php-" .. logs.sanitize_part(log_id) .. "-" .. logs.sanitize_part(phase) .. ".log"
    )
end

function logs.write_header(path, label, command, cwd)
    local file = io.open(path, "w")
    if not file then
        return false
    end

    file:write("# mise-php " .. label .. " log\n")
    file:write("# Started at: " .. logs.utc_timestamp() .. "\n")
    if cwd and cwd ~= "" then
        file:write("# Working directory: " .. cwd .. "\n")
    end
    if command and command ~= "" then
        file:write("# Command: " .. command .. "\n")
    end
    file:write("\n")
    file:close()

    return true
end

function logs.append(path, output)
    local file = io.open(path, "ab")
    if not file then
        return false
    end

    local text = tostring(output or "")
    if text ~= "" then
        file:write(text)
        if text:sub(-1) ~= "\n" then
            file:write("\n")
        end
    end

    file:close()
    return true
end

function logs.debug_tip(path, label)
    return "💡 Debug log: " .. path .. " (" .. label .. ")\n"
end

function logs.check_tip(path, label)
    return "💡 Tip: \27[93mCheck the " .. label .. " log for details:\27[0m " .. path .. "\n"
end

return logs
