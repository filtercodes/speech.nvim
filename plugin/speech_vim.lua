if vim.fn.exists(':SpeechGen') == 0 then
    vim.api.nvim_create_user_command('SpeechGen', function(opts)
        require('speech_vim').speech_gen(opts)
    end, {
        nargs = '?',
        range = true,
        complete = 'file',
    })
end

if vim.fn.exists(':Translate') == 0 then
    vim.api.nvim_create_user_command('Translate', function(opts)
        require('speech_vim.translation').translate(opts, require('speech_vim').config)
    end, {
        nargs = '*',
        range = true,
    })
end
