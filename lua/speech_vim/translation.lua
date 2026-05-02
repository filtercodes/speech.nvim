local M = {}

local function notify(msg, level)
    level = level or vim.log.levels.INFO
    vim.notify(msg, level, { title = "speech.nvim (Translate)" })
end

-- Helper to run shell commands asynchronously and capture output
local function run_job(cmd, on_exit)
    local output = {}
    local error_output = {}
    local job_id = vim.fn.jobstart(cmd, {
        stdout_buffered = true,
        stderr_buffered = true,
        on_stdout = function(_, data)
            for _, line in ipairs(data) do if line ~= "" then table.insert(output, line) end end
        end,
        on_stderr = function(_, data)
            for _, line in ipairs(data) do if line ~= "" then table.insert(error_output, line) end end
        end,
        on_exit = function(_, code)
            if on_exit then
                on_exit(code, table.concat(output, "\n"), table.concat(error_output, "\n"))
            end
        end
    })
    if job_id <= 0 and on_exit then on_exit(-1, "", "Failed to start job") end
end

function M.translate_gtx(text, sl, tl, callback)
    local url = "https://translate.googleapis.com/translate_a/single"
    local curl_cmd = {
        "curl", "-s",
        "-A", "Mozilla/5.0",
        url,
        "--get",
        "--data-urlencode", "client=gtx",
        "--data-urlencode", "dt=t",
        "--data-urlencode", "sl=" .. sl,
        "--data-urlencode", "tl=" .. tl,
        "--data-urlencode", "q=" .. text
    }

    run_job(curl_cmd, function(code, out, err)
        if code ~= 0 then
            notify("Translation failed: " .. err, vim.log.levels.ERROR)
            callback(nil)
            return
        end

        if out == "" then
            notify("Empty response from translation API", vim.log.levels.ERROR)
            callback(nil)
            return
        end

        local ok, resp = pcall(vim.fn.json_decode, out)
        if not ok or not resp or not resp[1] then
            notify("Failed to parse translation response", vim.log.levels.ERROR)
            callback(nil)
            return
        end

        -- resp[1] is an array of segments: [[translated, original, ...], ...]
        local translated_parts = {}
        for _, segment in ipairs(resp[1]) do
            if segment[1] then
                table.insert(translated_parts, segment[1])
            end
        end

        local translated_text = table.concat(translated_parts, "")
        callback(translated_text)
    end)
end

function M.translate(opts, config)
    local sl = 'auto'
    local tl = config.translation_target_lang or 'ja'
    
    local args = vim.split(opts.args, "%s+", { trimempty = true })
    if #args == 1 then
        tl = args[1]
    elseif #args >= 2 then
        sl = args[1]
        tl = args[2]
    end

    local start_line, end_line
    if opts.range > 0 then
        start_line = opts.line1 - 1
        end_line = opts.line2
    else
        start_line = 0
        end_line = -1
    end

    local lines = vim.api.nvim_buf_get_lines(0, start_line, end_line, false)
    local text = table.concat(lines, "\n")

    if not text or text:match("^%s*$") then
        notify("No text to translate", vim.log.levels.WARN)
        return
    end

    notify(string.format("Translating (%s -> %s)...", sl, tl))
    
    M.translate_gtx(text, sl, tl, function(translated_text)
        if not translated_text then return end
        
        local new_lines = vim.split(translated_text, "\n")
        vim.api.nvim_buf_set_lines(0, start_line, end_line, false, new_lines)
        notify("Translation complete", vim.log.levels.INFO)
    end)
end

return M
