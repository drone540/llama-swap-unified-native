# AI Stack Installer

Build and install a [llama-swap](https://github.com/mostlygeek/llama-swap)\-based,
self-hosted AI kit on Ubuntu (or other Debian-based Linux). Every model/pipeline
component is compiled **from source**, and each one gets its own compute backend
selected interactively and stored for reuse.

## What it installs

| Component | What it is | Builds |
|-----------|------------|--------|
| `llama` | llama.cpp main LLM engine | `llama-server`, `llama-cli`, `llama-tts` |
| `ik-llama` | ik_llama.cpp, an alternative server build | `ik-llama-server` |
| `sd` | stable-diffusion.cpp image generation | `sd-server`, `sd-cli` |
| `whisper` | whisper.cpp speech-to-text | `whisper-server`, `whisper-cli` |
| `kokoro` | Kokoro-FastAPI text-to-speech (Python service) | pip env |
| `crispasr` | CrispASR speech-to-text | `crispasr`, `crispasr-server` |
| `acestep` | acestep.cpp audio | `ace-server` |
| `audio` | audio.cpp audio (OpenAI-compatible TTS/ASR) | `audiocpp_cli`, `audiocpp_server` |

[llama-swap](https://github.com/mostlygeek/llama-swap) is always installed as the
model router / server manager.

## Requirements

* **Ubuntu 24.04** (or similar Debian-based distro; Metal is offered on macOS)
* A user with `sudo`
* Internet access (downloads source, toolchains, and prebuilt releases)
* Sufficient disk/RAM for compiling the components you pick

Everything else (cmake, build-essential, CGML build flags, the CUDA toolkit,
Vulkan dev packages, Node.js 24 via nvm) is installed automatically by the script.

## Usage

Clone this repository (or copy `install-ai-stack.sh`), then run:

```bash
sudo ./install-ai-stack.sh
```

On the **first run** you are asked which components to install, then which
compute backend each should use. Choices are saved to `/opt/ai/stack.conf`.

On **later runs** the saved config is reused automatically — nothing is
re-asked. To change your choices:

```bash
sudo ./install-ai-stack.sh --reconfigure
```

### Options

| Flag | Description |
|------|-------------|
| `--data-dir DIR` | Data/config/model directory (default `/var/lib/llama-swap`) |
| `--backend B` | Force every backend to `cuda`, `vulkan`, `hip`, `metal`, `sycl`, or `cpu` |
| `--component NAME` | Add a component to install; may be repeated |
| `--kokoro-device D` | Kokoro device: `gpu`, `gpu-cu128`, `cpu`, `rocm` (default `auto`) |
| `--cuda-archs AR` | CUDA architectures for CUDA builds (default native) |
| `-y`, `--yes` | Skip all prompts, using saved config + defaults |
| `--reconfigure` | Re-ask components and backends even if a config exists |
| `--uninstall` | Remove installed AI software |
| `--purge-data` | Also delete the data directory (with `--uninstall`) |
| `-h`, `--help` | Show full usage |

### Examples

```bash
# First-run interactive wizard (or reuse saved config)
sudo ./install-ai-stack.sh

# Change what's built / which backends
sudo ./install-ai-stack.sh --reconfigure

# Non-interactive full stack on the GPU backend
sudo ./install-ai-stack.sh -y --backend cuda

# Install just the LLM + whisper on CPU
sudo ./install-ai-stack.sh --component llama --component whisper --backend cpu
```

## Compute backends

Each component accepts the backends its upstream project officially supports:

* **CUDA** — NVIDIA GPUs. The CUDA toolkit is detected to match your driver's maximum supported CUDA version and installed from NVIDIA's official apt repo.
* **Vulkan** — NVIDIA, AMD or Intel boards. Installs `libvulkan-dev`, `glslc`, and `spirv-headers`.
* **HIP/ROCm** — AMD GPUs.
* **Metal** — Apple silicon (macOS).
* **SYCL** — Intel with oneAPI.
* **CPU** — always available.

Missing toolchains are installed with your confirmation; if a chosen backend
can't be provisioned, that component falls back to CPU with a warning.

## Where things land

* **Binaries / config / versions** → `/opt/ai` 
  * Executables → `/opt/ai/bin`
  * Saved choices → `/opt/ai/stack.conf`
  * Installed versions → `/opt/ai/versions.txt`
* **Models / data / server config** → `/var/lib/llama-swap`
* **Node.js 24** (for the web UI) → installed via nvm into your home, with `node`/`npm`/`npx` symlinked into `/usr/local/bin`.

Add the bin dir to your shell if it isn't already on `PATH`:

```bash
echo 'export PATH=/opt/ai/bin:$PATH' >> ~/.bashrc
```

## Notes

* **Source revisions are not pinned.** Each component is built from whatever revision is currently checked out in its cloned directory, so results can change as upstream advances. For a fully reproducible build, check out a known commit in each upstream repo before running the installer.
* Components are compiled locally, so builds take time; only the components you select are built.
* `--uninstall` removes the installed software but leaves the source clones and downloaded models unless you pass `--purge-data`.

## License

This installer script is released under the MIT License. Note that it compiles
and installs third-party projects (llama.cpp, whisper.cpp, etc.) which are each
licensed separately by their respective authors.