# AI Stack Installer

Build and install a [llama-swap](https://github.com/mostlygeek/llama-swap)-based,
self-hosted AI kit on Ubuntu (or other Debian-based Linux). Every model/pipeline
component is compiled **from source**, and each one gets its own compute backend
selected interactively and stored for reuse.

## What it installs

| Component | What it is | Builds |
|-----------|------------|--------|
| `llama`    | llama.cpp main LLM engine | `llama-server`, `llama-cli`, `llama-tts` |
| `ik-llama` | ik_llama.cpp, an alternative server build | `ik-llama-server` |
| `sd`       | stable-diffusion.cpp image generation | `sd-server`, `sd-cli` |
| `whisper`  | whisper.cpp speech-to-text | `whisper-server`, `whisper-cli` |
| `kokoro`   | Kokoro-FastAPI text-to-speech (Python service) | pip env |
| `crispasr` | CrispASR speech-to-text | `crispasr`, `crispasr-server` |
| `acestep`  | acestep.cpp audio | `ace-server` |
| `audio`    | audio.cpp audio (OpenAI-compatible TTS/ASR) | `audiocpp_cli`, `audiocpp_server` |

[llama-swap](https://github.com/mostlygeek/llama-swap) is always installed as the
model router / server manager.

## Requirements

- **Ubuntu 24.04** (or similar Debian-based distro; Metal is offered on macOS)
- A user with `sudo`
- Internet access (downloads source, toolchains, and prebuilt releases)
- Sufficient disk/RAM for compiling the components you pick

Everything else (cmake, build-essential, CMake build flags, the CUDA toolkit,
Vulkan dev packages, Node.js 24 via nvm) is installed automatically by the
script. Component source repositories are also cloned for you if they aren't
already present next to the script:

## Usage

Clone this repository (or copy `install-ai-stack.sh`), then run:

```bash
./install-ai-stack.sh
```

Run it **as a normal user** — not with `sudo`. The installer uses `sudo` only for
the specific operations that genuinely need root (system packages, the
`/opt/ai-stack` tree, the systemd service, swap files). All building, cloning,
and package downloads happen under your account.

On the **first run** you are asked which components to install, then which
compute backend each should use. Choices are saved to `/opt/ai-stack/stack.conf`.

On **later runs** the saved config is reused automatically — nothing is
re-asked. To change your choices:

```bash
./install-ai-stack.sh --reconfigure
```

### Options

| Flag | Description |
|------|-------------|
| `--data-dir DIR` | Data/config/model directory (default `/var/lib/llama-swap`) |
| `--backend B` | Force every backend to `cuda`, `vulkan`, `hip`, `metal`, `sycl`, or `cpu` |
| `--component NAME` | Add a component to install; may be repeated |
| `--kokoro-device D` | Kokoro device: `gpu`, `gpu-cu128`, `cpu`, `rocm` (default `auto`) |
| `--cuda-archs AR` | CUDA architectures for CUDA builds (default native) |
| `--jobs N` | Number of parallel build jobs (default: auto by RAM, capped at nproc) |
| `--swap-size SIZE` | Swap file size offered by the low-memory prompt (default `8G`) |
| `--no-swap` | Never create or prompt about swap files |
| `-y`, `--yes` | Skip all prompts, using saved config + defaults |
| `--reconfigure` | Re-ask components and backends even if a config exists |
| `--uninstall` | Remove installed AI software |
| `--purge-data` | Also delete the data directory (with `--uninstall`) |
| `-h`, `--help` | Show full usage |

### Examples

```bash
# First-run interactive wizard (or reuse saved config)
./install-ai-stack.sh

# Change what's built / which backends
./install-ai-stack.sh --reconfigure

# Non-interactive full stack on the GPU backend
./install-ai-stack.sh -y --backend cuda

# Install just the LLM + whisper on CPU, 6 parallel jobs
./install-ai-stack.sh --component llama --component whisper --backend cpu --jobs 6
```

## Compute backends

Each component accepts the backends its upstream project officially supports:

- **CUDA** — NVIDIA GPUs. The CUDA toolkit is installed from NVIDIA's official
  apt repo. When multiple versions are compatible with your driver you are asked
  which to install: 12.8 (most stable), 13.0, or 13.3. The problematic 13.1/13.2
  releases are always excluded.
- **Vulkan** — NVIDIA, AMD or Intel boards. Installs `libvulkan-dev`, `glslc`,
  and `spirv-headers`.
- **HIP/ROCm** — AMD GPUs.
- **Metal** — Apple silicon (macOS).
- **SYCL** — Intel with oneAPI.
- **CPU** — always available.

Missing toolchains are installed with your confirmation; if a chosen backend
can't be provisioned, that component falls back to CPU with a warning.

## Where things land

- **Binaries / config / versions** → `/opt/ai-stack` (root-owned)
  - Executables → `/opt/ai-stack/bin`
  - Saved choices → `/opt/ai-stack/stack.conf`
  - Installed versions → `/opt/ai-stack/versions.txt`
- **Source repositories** → `~/.local/share/ai-stack/src/`
  (e.g. `llama.cpp/`, `whisper.cpp/`) — cloned automatically if missing;
  user-owned, so you can `git pull` or `git checkout` freely
- **Build directories** → `~/.cache/ai-stack/build/<component>/` — kept
  outside the source trees, user-owned
- **Models / data / server config** → `/var/lib/llama-swap` (owned by the
  `llama-swap` system account that runs the service)
- **Node.js 24** (for the web UI) → installed via nvm into your home, with
  `node`/`npm`/`npx` symlinked into `/usr/local/bin`.

During a real run, if your total RAM+swap is below 16 GiB the installer warns.
Extra swap is only offered when the heavy `audio.cpp` build is selected. If you
accept, it handles whatever swap you already have:

- `/swapfile` already large enough → nothing to do,
- active `/swapfile` too small → offer to **resize it** or add a **temporary
  swapfile** that is removed when the run finishes,
- no `/swapfile` → create one (`fallocate`, persisted in `/etc/fstab`).

`--no-swap` never creates or prompts about swap; `-y` always continues without
extra swap.

Add the bin dir to your shell if it isn't already on `PATH`:

```bash
echo 'export PATH=/opt/ai-stack/bin:$PATH' >> ~/.bashrc
```

## Notes

- **Source repositories are cloned automatically** into `~/.local/share/ai-stack/src`
  (e.g. `llama.cpp/`, `whisper.cpp/`) when they don't already exist. If a
  directory already exists it is left untouched — you can `git pull` to update
  or `git checkout` a specific revision to build it.
- **Builds happen in `~/.cache/ai-stack/build`, not inside the source trees**,
  and all downloads/clones/builds run as your user. Only installation into
  `/opt/ai-stack`, system packages, and the service file use `sudo`.
- **Source revisions are not pinned.** Each component is built from whatever
  revision is currently checked out in its cloned directory, so results can
  change as upstream advances. For a fully reproducible build, check out a known
  commit in each upstream repo before running the installer.
- **Installed versions are tracked by release** (`/opt/ai-stack/versions.txt`):
  the git tag at or near the checked-out revision (e.g. `b10733`, `v1.9.3`,
  `v0.8.31`), falling back to the commit hash when a repo has no tags. These
  change only when upstream cuts a new release.
- **Already-current components are skipped.** If a component's recorded version
  still matches the version currently checked out in its clone, and its installed
  binary is still on disk, the build is skipped (`<comp> is already up to date`).
  Pass `--reconfigure` to force a rebuild (e.g. after changing a backend).
- **Kokoro** creates its venv with uv, downloads the model weights, and (on
  confirmation, default yes) the ~526MB UniDic dictionary for **Japanese TTS**.
  The dictionary is only downloaded when it is actually missing from the venv, so
  repeated installs don't re-fetch it. The `kokoro-fastapi` launcher runs uvicorn
  from the project's `.venv` (no `uv` needed at runtime), and the build-only
  packages (`python3-dev`, `python3-venv`) are purged after the install finishes.
- **Builds are tuned for this machine.** CMake builds use `GGML_NATIVE=ON` (code
  is optimized for the local CPU) and CUDA builds add
  `GGML_CUDA_FA_ALL_QUANTS=ON` for full flash-attention coverage.
- **sd-server's webui is built.** If `sd` is selected, Node 24 (via nvm) is
  installed and pnpm is enabled through corepack into `~/.local/bin` so the
  webui frontend (`examples/server/frontend`) is compiled in. A pre-built
  `gen_index_html.h` is used as a fallback if pnpm is unavailable.
- **Selections are saved before building**, so a failed build doesn't discard
  your component/backend choices; the next run resumes from them.
- Components are compiled locally, so builds take time; only the components you
  select are built. Parallelism is scaled off total RAM+swap (1 job under 4 GiB,
  2 under 6 GiB, 3 under 8 GiB, 4 under 12 GiB, 6 under 16 GiB, else all cores;
  `--jobs N` to override, capped at your CPU count).
- `--uninstall` removes the installed software and the systemd service but leaves
  your source clones, build cache, and downloaded models unless you pass
  `--purge-data`.

## License

This installer script is released under the MIT License. Note that it compiles
and installs third-party projects (llama.cpp, whisper.cpp, etc.) which are each
licensed separately by their respective authors.