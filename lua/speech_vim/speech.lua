local M = {}
local utils = require('speech_vim.utils')

function M.speech_gen(opts, config)
    local lines = (opts.range > 0) and vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false) or vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local text = table.concat(lines, "\n")

    if not text or text:match("^%s*$") then
        utils.notify("No text to synthesize", vim.log.levels.WARN)
        return
    end

    local output_file = (opts.args and opts.args ~= "") and opts.args or "output.wav"
    output_file = vim.fn.expand(output_file)

    if config.engine == 'local' then
        M._start_pipeline(text, output_file, nil, nil, config)
    else
        utils.notify("Authenticating with Google Cloud...", vim.log.levels.INFO)
        utils.run_job({"gcloud", "config", "list", "--format=value(core.project)"}, function(code1, project_id, err1)
            project_id = utils.trim(project_id)
            if code1 ~= 0 or project_id == "" then
                utils.notify("GCloud Project ID error: " .. err1, vim.log.levels.ERROR)
                return
            end

            utils.run_job({"gcloud", "auth", "print-access-token"}, function(code2, access_token, err2)
                access_token = utils.trim(access_token)
                if code2 ~= 0 or access_token == "" then
                    local msg = (err2:match("re%-authenticate") or err2:match("login")) and "Session expired. Run 'gcloud auth login'." or ("Auth error: " .. err2)
                    utils.notify(msg, vim.log.levels.ERROR)
                    return
                end
                M._start_pipeline(text, output_file, project_id, access_token, config)
            end)
        end)
    end
end

function M._start_pipeline(text, output_file, project_id, access_token, config)
    local chunks = utils.split_text(text, config.chunk_size)
    local tmp_files = {}
    
    local function process_next(index)
        if index > #chunks then
            M._finalize(tmp_files, output_file, config)
            return
        end

        if #chunks > 1 then utils.notify(string.format("Processing chunk %d/%d...", index, #chunks), vim.log.levels.INFO) end
        
        M._synthesize_chunk(chunks[index], project_id, access_token, config, function(tmp_wav)
            if not tmp_wav then return end
            table.insert(tmp_files, tmp_wav)
            process_next(index + 1)
        end)
    end

    process_next(1)
end

function M._synthesize_chunk(text, project_id, access_token, config, callback)
    local tmp_json = vim.fn.tempname() .. ".json"
    local is_google = (config.engine == 'google')
    local curl_cmd = { "curl", "-s" }

    if is_google then
        local voice_name = config.default_voice
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
            model = config.local_model,
            input = text,
            voice = config.local_voice,
            response_format = "wav"
        }
        local f = io.open(tmp_json, "w")
        if f then f:write(vim.fn.json_encode(payload)) f:close() end
        vim.list_extend(curl_cmd, {"-X", "POST", "-H", "Content-Type: application/json", "-d", "@" .. tmp_json, config.local_url})
        if config.local_api_key ~= "" then
            vim.list_extend(curl_cmd, {"-H", "Authorization: Bearer " .. config.local_api_key})
        end
    end

    local tmp_wav = vim.fn.tempname() .. ".wav"
    
    -- Local engine returns binary stream, Google returns JSON
    if not is_google then
        table.insert(curl_cmd, "-o")
        table.insert(curl_cmd, tmp_wav)
    end

    utils.run_job(curl_cmd, function(code, out, err)
        os.remove(tmp_json)
        
        if is_google then
            local ok, resp = pcall(vim.fn.json_decode, out)
            if not ok or not resp or resp.error or not resp.audioContent then
                utils.notify("API Error: " .. (resp and resp.error and resp.error.message or (err ~= "" and err or "Unknown")), vim.log.levels.ERROR)
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
                utils.notify("Local API Error: " .. (err ~= "" and err or "Exit code " .. code), vim.log.levels.ERROR)
                callback(nil)
                return
            end
        end

        -- Check file existence and size
        local chk = io.open(tmp_wav, "rb")
        local size = chk and chk:seek("end") or 0
        if chk then chk:close() end
        
        if size == 0 then
            utils.notify("Generated audio chunk is empty.", vim.log.levels.ERROR)
            callback(nil)
        else
            callback(tmp_wav)
        end
    end)
end

function M._finalize(tmp_files, output_file, config)
    if #tmp_files == 0 then return end
    local final_raw = vim.fn.tempname() .. ".wav"
    
    if #tmp_files == 1 then
        os.rename(tmp_files[1], final_raw)
        M._apply_filters(final_raw, output_file, config)
    else
        utils.notify("Merging chunks...", vim.log.levels.INFO)
        local list_file = vim.fn.tempname() .. ".txt"
        local lf = io.open(list_file, "w")
        if lf then
            for _, f in ipairs(tmp_files) do lf:write(string.format("file '%s'\n", f)) end
            lf:close()
        end

        local concat_cmd = {"ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", list_file, "-c", "copy", final_raw}
        utils.run_job(concat_cmd, function(code, _, err)
            os.remove(list_file)
            for _, f in ipairs(tmp_files) do os.remove(f) end
            if code ~= 0 then 
                utils.notify("Merge failed: " .. err, vim.log.levels.ERROR) 
                return 
            end
            M._apply_filters(final_raw, output_file, config)
        end)
    end
end

function M._apply_filters(tmp_wav, output_file, config)
    if config.factor == 1.0 and config.pitch_shift == 0.0 then
        M._run_final_ffmpeg(tmp_wav, output_file, config)
    else
        local tmp_rb = vim.fn.tempname() .. ".wav"
        local tempo = 1.0 / config.factor
        
        utils.run_job({"rubberband", "-t", tostring(tempo), "-p", tostring(config.pitch_shift), tmp_wav, tmp_rb}, function(code, _, err)
            os.remove(tmp_wav)
            if code ~= 0 then utils.notify("Rubberband error: " .. err, vim.log.levels.ERROR) return end
            M._run_final_ffmpeg(tmp_rb, output_file, config)
        end)
    end
end

function M._run_final_ffmpeg(input_wav, output_file, config)
    local filter = string.format("highpass=f=20,afade=t=in:ss=0:d=%.3f", config.fade_in_ms / 1000.0)
    utils.run_job({"ffmpeg", "-y", "-v", "error", "-i", input_wav, "-af", filter, output_file}, function(code, _, err)
        os.remove(input_wav)
        if code == 0 then
            utils.notify("🗣️ Generated: " .. output_file, vim.log.levels.INFO)
        else
            utils.notify("FFmpeg filter error: " .. err, vim.log.levels.ERROR)
        end
    end)
end

return M
