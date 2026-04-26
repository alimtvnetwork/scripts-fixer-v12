43-install-llama-cpp
====================
let's start now 2026-04-26 (Asia/Kuala_Lumpur)

Title:    llama.cpp (CPU-first local LLM inference, built from source)
Method:   apt deps + git clone + cmake build, symlinked into ~/.local/bin
Repo:     https://github.com/ggerganov/llama.cpp
Source:   ~/.local/src/llama.cpp
Build:    ~/.local/src/llama.cpp/build (out-of-tree)
Binaries: ~/.local/bin/{llama-cli,llama-server,llama-quantize} (symlinks)
Verify:   ~/.local/bin/llama-cli --version

Note: GPU acceleration (CUDA/Metal/Vulkan) requires extra cmake flags;
      this script builds CPU-only with -DGGML_NATIVE=ON for portable performance.
