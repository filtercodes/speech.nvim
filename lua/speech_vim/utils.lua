local M = {}

-- Notify helper
function M.notify(msg, level)
    level = level or vim.log.levels.INFO
    vim.notify(msg, level, { title = "speech.nvim" })
end

function M.trim(s)
    return s:match("^%s*(.-)%s*$")
end

-- Helper to run shell commands asynchronously and capture output
function M.run_job(cmd, on_exit)
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

-- Safely split text at UTF-8 boundaries and newlines
function M.split_text(text, max_bytes)
    local chunks = {}
    local start = 1
    while start <= #text do
        if #text - start < max_bytes then
            table.insert(chunks, string.sub(text, start))
            break
        end
        
        local end_idx = start + max_bytes - 1
        local break_point = text:sub(start, end_idx):match(".*()\n") or text:sub(start, end_idx):match(".*() ")
        
        if break_point and break_point > (max_bytes * 0.3) then
            table.insert(chunks, text:sub(start, start + break_point - 1))
            start = start + break_point
        else
            local safe_end = end_idx
            while safe_end > start and (text:byte(safe_end + 1) or 0) >= 128 and (text:byte(safe_end + 1) or 0) < 192 do
                safe_end = safe_end - 1
            end
            table.insert(chunks, text:sub(start, safe_end))
            start = safe_end + 1
        end
    end
    return chunks
end

return M
