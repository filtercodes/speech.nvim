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
    translation_target_lang = 'ja', -- Default target language
}

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    
    vim.api.nvim_create_user_command('SpeechGen', function(args)
        require('speech_vim.speech').speech_gen(args, M.config)
    end, {
        nargs = '?',
        range = true,
        complete = 'file',
    })

    vim.api.nvim_create_user_command('Translate', function(args)
        require('speech_vim.translation').translate(args, M.config)
    end, {
        nargs = '*',
        range = true,
    })
end

return M
