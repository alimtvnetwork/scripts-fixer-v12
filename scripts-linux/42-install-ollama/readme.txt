42-install-ollama
=================
let's start now 2026-04-26 (Asia/Kuala_Lumpur)

Title:    Ollama (local LLM runtime)
Method:   Official curl install script from https://ollama.com/install.sh
Binary:   /usr/local/bin/ollama
Service:  systemd unit "ollama" (registered by official installer when systemd present)
Verify:   ollama --version

Note: GPU detection (CUDA / ROCm) is handled by the official installer.
