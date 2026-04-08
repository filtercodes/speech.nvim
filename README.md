# 🗣️ speech.nvim

A lightweight, Lua Neovim plugin that converts text into spoken audio using the Google Cloud Text-to-Speech API or a local model that complies with OpenAI speech API specification. You can synthesize the entire buffer or just a visual selection, and save the output as `.wav` or `.mp3`.

## ✨ Features

- **Buffer or Selection:** Synthesize an entire file or just the text highlighted in visual mode.
- **Format Support:** Automatically saves as `.wav` or converts to `.mp3` using `ffmpeg` based on your output file extension.
- **Audio Processing:** Includes built-in fade-ins, pitch shifting, and time stretching for smoother audio playback.

## 🛠️ Prerequisites

The plugin requires a few common command-line tools under the hood for audio processing:

### 1. System Dependencies
You will need `curl`, `ffmpeg` (for MP3 conversion and filters), and `rubberband` (for audio time-stretching/pitch-shifting).

**macOS (Homebrew):**
```bash
brew install curl ffmpeg rubberband
```

**Ubuntu/Debian:**
```bash
sudo apt-get install curl ffmpeg rubberband-cli
```

### 2. Google Cloud CLI (`gcloud`)
The plugin authenticates using your local `gcloud` configuration.
1. Install the [Google Cloud CLI](https://cloud.google.com/sdk/docs/install).
2. Authenticate and set your project:
```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

## 📦 Installation & Configuration

Install the plugin using your preferred package manager and configure the engine.

### [Lazy.nvim](https://github.com/folke/lazy.nvim)
```lua
{
    'your-username/speech.nvim', -- Or local path: dir = '~/path/to/speech_vim'
    opts = {
        -- Engine selection: 'google' (default) or 'local'
        engine = 'google',

        -- ==== GOOGLE ENGINE SETTINGS ====
        default_voice = 'en-GB-Wavenet-N',

        -- ==== LOCAL ENGINE SETTINGS ====
        -- Use any local OpenAI-compatible API server (e.g., Fish-Speech, F5-TTS)
        local_url = 'http://localhost:8080/v1/audio/speech',
        local_voice = 'alloy', -- Change to your cloned voice profile name
        local_api_key = '',    -- Optional, if your local server requires it
        local_model = 'tts-1',

        -- ==== AUDIO PROCESSING SETTINGS ====
        -- Speed multiplier (1.0 = normal, 0.5 = double speed)
        factor = 0.81,
        
        -- Pitch shift in semitones (0.0 = normal, negative = lower, positive = higher)
        pitch_shift = -0.5,
    }
}
```

### [Packer](https://github.com/wbthomason/packer.nvim)
```lua
use {
    'your-username/speech.nvim', -- Or local path: '~/path/to/speech_vim'
    config = function()
        require('speech_vim').setup({
            engine = 'local', -- Example: Switching to a local model
            local_url = 'http://localhost:8080/v1/audio/speech',
            local_voice = 'my_custom_voice',
            factor = 1.0,     -- Example: Disable time-stretching
            pitch_shift = 0.0 -- Example: Disable pitch-shifting
        })
    end
}
```

## 🚀 Usage

To create speech from text run a command: `:SpeechGen audio/file/path.wav`

### Examples

**1. Synthesize the entire buffer (defaults to `output.wav`)**
```vim
:SpeechGen
```

**2. Synthesize a specific file and format**
If you provide an `.mp3` extension, the plugin will use `ffmpeg` to convert it.
```vim
:SpeechGen ~/Desktop/my_audio.mp3
```

**3. Synthesize selected text**
Select text in Visual mode, then type the command:
```vim
:'<,'>SpeechGen selection.wav
```

**4. If you want to make pitch (or speed) changes temporarily and without restarting Neovim, you can run this command directly in the Neovim command line: 
```vim
:lua require('speech_vim').config.pitch_shift = 2.0 
```
and then run `:SpeechGen` as usual.

## 📝 License

MIT
