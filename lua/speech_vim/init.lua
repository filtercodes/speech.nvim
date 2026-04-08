local M = {}

M.config = {
    engine = 'google',           -- 'google' or 'local'
    default_voice = 'en-GB-Wavenet-N',
    
    -- Local Engine settings (standard OpenAI API spec)
    local_url = 'http://localhost:8080/v1/audio/speech',
    local_voice = 'alloy',
    local_api_key = '',
    local_model = 'tts-1',

    -- Audio Processing Settings
    factor = 0.81,        -- Speed multiplier (1.0 = normal)
    pitch_shift = -0.5,   -- Pitch shift in semitones (0.0 = normal)
    fade_in_ms = 10,      -- Fade in duration
    chunk_size = 4000,    -- Bytes per request
}

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    
    vim.api.nvim_create_user_command('SpeechGen', function(args)
        M.speech_gen(args)
    end, {
        nargs = '?',
        range = true,
        complete = 'file',
    })
end

-- Notify helper
local function notify(msg, level)
    level = level or vim.log.levels.INFO
    vim.notify(msg, level, { title = "speech.nvim" })
end

local function trim(s)
    return s:match("^%s*(.-)%s*$")
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

-- Safely split text at UTF-8 boundaries and newlines
local function split_text(text, max_bytes)
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

function M.speech_gen(opts)
    local lines = (opts.range > 0) and vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false) or vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local text = table.concat(lines, "\n")

    if not text or text:match("^%s*$") then
        notify("No text to synthesize", vim.log.levels.WARN)
        return
    end

    local output_file = (opts.args and opts.args ~= "") and opts.args or "output.wav"
    output_file = vim.fn.expand(output_file)

    if M.config.engine == 'local' then
        M._start_pipeline(text, output_file, nil, nil)
    else
        notify("Authenticating with Google Cloud...", vim.log.levels.INFO)
        run_job({"gcloud", "config", "list", "--format=value(core.project)"}, function(code1, project_id, err1)
            project_id = trim(project_id)
            if code1 ~= 0 or project_id == "" then
                notify("GCloud Project ID error: " .. err1, vim.log.levels.ERROR)
                return
            end

            run_job({"gcloud", "auth", "print-access-token"}, function(code2, access_token, err2)
                access_token = trim(access_token)
                if code2 ~= 0 or access_token == "" then
                    local msg = (err2:match("re%-authenticate") or err2:match("login")) and "Session expired. Run 'gcloud auth login'." or ("Auth error: " .. err2)
                    notify(msg, vim.log.levels.ERROR)
                    return
                end
                M._start_pipeline(text, output_file, project_id, access_token)
            end)
        end)
    end
end

function M._start_pipeline(text, output_file, project_id, access_token)
    local chunks = split_text(text, M.config.chunk_size)
    local tmp_files = {}
    
    local function process_next(index)
        if index > #chunks then
            M._finalize(tmp_files, output_file)
            return
        end

        if #chunks > 1 then notify(string.format("Processing chunk %d/%d...", index, #chunks), vim.log.levels.INFO) end
        
        M._synthesize_chunk(chunks[index], project_id, access_token, function(tmp_wav)
            if not tmp_wav then return end
            table.insert(tmp_files, tmp_wav)
            process_next(index + 1)
        end)
    end

    process_next(1)
end

function M._synthesize_chunk(text, project_id, access_token, callback)
    local tmp_json = vim.fn.tempname() .. ".json"
    local is_google = (M.config.engine == 'google')
    local curl_cmd = { "curl", "-s" }

    if is_google then
        local voice_name = M.config.default_voice
        local payload = {
            input = { text = text },
            voice = { languageCode = voice_name:match("^(%w+%-%w+)%-") or "en-GB", name = voice_name },
            audioConfig = { audioEncoding = "LINEAR16" }
        }
        local f = io.open(tmp_json, "w")
        if f then f:write(vim.fn.json_encode(payload)) f:close() end
        vim.list_extend(curl_cmd, {"-X", "POST", "-H", "Content-Type: application/json", "-H", "X-Goog-User-Project: " .. project_id, "-H", "Authorization: Bearer " .. access_token, "-d", "@" .. tmp_json, "https://texttospeech.googleapis.com/v1/text:synthesize"})
    else
        -- Local Engine (OpenAI Spec)
        local payload = {
            model = M.config.local_model,
            input = text,
            voice = M.config.local_voice,
            response_format = "wav"
        }
        local f = io.open(tmp_json, "w")
        if f then f:write(vim.fn.json_encode(payload)) f:close() end
        vim.list_extend(curl_cmd, {"-X", "POST", "-H", "Content-Type: application/json", "-d", "@" .. tmp_json, M.config.local_url})
        if M.config.local_api_key ~= "" then
            vim.list_extend(curl_cmd, {"-H", "Authorization: Bearer " .. M.config.local_api_key})
        end
    end

    local tmp_wav = vim.fn.tempname() .. ".wav"
    
    -- Local engine returns binary stream, Google returns JSON
    if not is_google then
        table.insert(curl_cmd, "-o")
        table.insert(curl_cmd, tmp_wav)
    end

    run_job(curl_cmd, function(code, out, err)
        os.remove(tmp_json)
        
        if is_google then
            local ok, resp = pcall(vim.fn.json_decode, out)
            if not ok or not resp or resp.error or not resp.audioContent then
                notify("API Error: " .. (resp and resp.error and resp.error.message or (err ~= "" and err or "Unknown")), vim.log.levels.ERROR)
                callback(nil)
                return
            end

            -- Decode Base64 from Google JSON
            if vim.base64 and vim.base64.decode then
                local raw = vim.base64.decode(resp.audioContent)
                local wf = io.open(tmp_wav, "wb")
                if wf then wf:write(raw) wf:close() end
            else
                local tmp_b64 = vim.fn.tempname() .. ".b64"
                local bf = io.open(tmp_b64, "w")
                if bf then bf:write(resp.audioContent) bf:close() end
                local decode_cmd = string.format('cat "%s" | base64 -d > "%s" 2>/dev/null || cat "%s" | base64 -D > "%s"', tmp_b64, tmp_wav, tmp_b64, tmp_wav)
                vim.fn.system(decode_cmd)
                os.remove(tmp_b64)
            end
        else
            -- Local logic: File was already saved via curl -o
            if code ~= 0 then
                notify("Local API Error: " .. (err ~= "" and err or "Exit code " .. code), vim.log.levels.ERROR)
                callback(nil)
                return
            end
        end

        -- Check file existence and size
        local chk = io.open(tmp_wav, "rb")
        local size = chk and chk:seek("end") or 0
        if chk then chk:close() end
        
        if size == 0 then
            notify("Generated audio chunk is empty.", vim.log.levels.ERROR)
            callback(nil)
        else
            callback(tmp_wav)
        end
    end)
end

function M._finalize(tmp_files, output_file)
    if #tmp_files == 0 then return end
    local final_raw = vim.fn.tempname() .. ".wav"
    
    if #tmp_files == 1 then
        os.rename(tmp_files[1], final_raw)
        M._apply_filters(final_raw, output_file)
    else
        notify("Merging chunks...", vim.log.levels.INFO)
        local list_file = vim.fn.tempname() .. ".txt"
        local lf = io.open(list_file, "w")
        if lf then
            for _, f in ipairs(tmp_files) do lf:write(string.format("file '%s'\n", f)) end
            lf:close()
        end

        local concat_cmd = {"ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", list_file, "-c", "copy", final_raw}
        run_job(concat_cmd, function(code, _, err)
            os.remove(list_file)
            for _, f in ipairs(tmp_files) do os.remove(f) end
            if code ~= 0 then 
                notify("Merge failed: " .. err, vim.log.levels.ERROR) 
                return 
            end
            M._apply_filters(final_raw, output_file)
        end)
    end
end

function M._apply_filters(tmp_wav, output_file)
    if M.config.factor == 1.0 and M.config.pitch_shift == 0.0 then
        M._run_final_ffmpeg(tmp_wav, output_file)
    else
        local tmp_rb = vim.fn.tempname() .. ".wav"
        local tempo = 1.0 / M.config.factor
        
        run_job({"rubberband", "-t", tostring(tempo), "-p", tostring(M.config.pitch_shift), tmp_wav, tmp_rb}, function(code, _, err)
            os.remove(tmp_wav)
            if code ~= 0 then notify("Rubberband error: " .. err, vim.log.levels.ERROR) return end
            M._run_final_ffmpeg(tmp_rb, output_file)
        end)
    end
end

function M._run_final_ffmpeg(input_wav, output_file)
    local filter = string.format("highpass=f=20,afade=t=in:ss=0:d=%.3f", M.config.fade_in_ms / 1000.0)
    run_job({"ffmpeg", "-y", "-v", "error", "-i", input_wav, "-af", filter, output_file}, function(code, _, err)
        os.remove(input_wav)
        if code == 0 then
            notify("🗣️ Generated: " .. output_file, vim.log.levels.INFO)
        else
            notify("FFmpeg filter error: " .. err, vim.log.levels.ERROR)
        end
    end)
end

return M
