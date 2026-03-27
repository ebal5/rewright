# rewright

A local-first speech-to-text dictation tool written in Zig, inspired by [OpenWhispr](https://github.com/OpenWhispr/openwhispr) / SuperWhisper.

## Features

- Local speech-to-text inference via [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (no cloud dependency)
- Optional LLM text cleanup through any OpenAI-compatible API
- Clipboard hook for pasting transcriptions directly
- Cross-platform: Windows (primary target) and Linux
- CLI-based (GUI planned -- see [Roadmap](#status))

## Requirements

- [Zig](https://ziglang.org/) 0.15.2
- git (for submodules)

## Build

```sh
git clone --recursive https://github.com/ebal5/rewright.git
cd rewright
zig build
```

Cross-compile for Windows from Linux:

```sh
zig build -Dtarget=x86_64-windows
```

Release build:

```sh
zig build -Doptimize=ReleaseSafe
```

### GPU backends (WIP)

CUDA and Vulkan options exist but require additional setup (pre-compiled shaders, nvcc, etc.). See comments in `build.zig` for details.

```sh
zig build -Dcuda=true    # Requires CUDA Toolkit
zig build -Dvulkan=true  # Requires Vulkan SDK + pre-compiled SPIR-V shaders
```

## Usage

```
Usage: rewright [OPTIONS]

Options:
  --list-models          List available whisper models
  --download-model NAME  Download a whisper model
  --language CODE        Whisper language (e.g. "en", "ja")
  --model PATH           Path to whisper model file
  --llm-url URL          OpenAI-compatible API endpoint
  --llm-key KEY          API key for LLM service
  --llm-model NAME       LLM model name (default: gpt-4o-mini)
  --verbose              Enable verbose logging
  --clipboard            Enable clipboard hook
  --help                 Show this help message

Environment variables:
  WHISPER_MODEL       Path to whisper model file
  WHISPER_LANGUAGE    Language code (e.g. "en", "ja") or "auto"
  LLM_API_URL         OpenAI-compatible API endpoint
  LLM_API_KEY         API key for LLM service
  LLM_MODEL           LLM model name (default: gpt-4o-mini)
  REWRIGHT_VERBOSE    Enable verbose logging (set to any value)
  REWRIGHT_CLIPBOARD  Enable clipboard hook (set to any value)
```

CLI arguments take priority over environment variables.

### Quick start

Download a model:

```sh
rewright --download-model base
```

Basic dictation (press Enter to start/stop recording):

```sh
rewright --language ja
```

With LLM text cleanup and clipboard output:

```sh
rewright --language ja --llm-key sk-xxx --clipboard
```

## Model management

List available models and their download status:

```sh
rewright --list-models
```

Download a model by name:

```sh
rewright --download-model <name>
```

Supported models:

| Name   | Size    | Filename                   |
|--------|---------|----------------------------|
| tiny   | ~75MB   | ggml-tiny.bin              |
| base   | ~142MB  | ggml-base.bin (default)    |
| small  | ~466MB  | ggml-small.bin             |
| medium | ~1.5GB  | ggml-medium.bin            |
| large  | ~3GB    | ggml-large-v3.bin          |
| turbo  | ~1.6GB  | ggml-large-v3-turbo.bin    |

Models are downloaded from HuggingFace and stored in a platform-appropriate cache directory (`$XDG_CACHE_HOME/rewright/models` on Linux, `%LOCALAPPDATA%\rewright\models` on Windows).

## Status

MVP -- CLI dictation works end-to-end. GPU backends (CUDA, Vulkan) and a Windows GUI are planned. See [docs/TODO.md](docs/TODO.md) for the full roadmap.

## License

MIT. See [LICENSE](LICENSE).

Third-party attribution details are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).

## Acknowledgements

- [OpenWhispr](https://github.com/OpenWhispr/openwhispr) -- the Electron-based dictation app that inspired this project
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) -- C/C++ port of OpenAI's Whisper, used as the inference engine
- [miniaudio](https://github.com/mackron/miniaudio) -- cross-platform audio capture library
