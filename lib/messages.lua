local env = require("lib/env")

local M = {}

function M.verbose_tip(version)
    if env.VERBOSE then
        return "💡 Verbose mode is enabled; full output will be shown.\n"
    end

    return "💡 Tip: \27[93mRun 'PHP_VERBOSE=1 mise install php@" .. (version or "VERSION") .. "'\27[0m to see the full output.\n"
end

function M.manual_tip(command)
    return "💡 Tip: \27[93mRun '" .. command .. "'\27[0m manually after installation to confirm it works.\n"
end

function M.see(anchor)
    return "→ See: https://github.com/verzly/mise-php#" .. anchor .. "\n"
end

return M
