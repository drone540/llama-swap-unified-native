#!/usr/bin/env bash
#
# install-ai-stack.sh - Install a llama-swap based AI stack by compiling each
# component from source.
#
# Each component's compute backend (CUDA, Vulkan, HIP, Metal, SYCL, CPU) is
# selected interactively and persisted in /opt/ai-stack/stack.conf so a later
# run reuses your choices.
#
# This installer must be run as a NORMAL (non-root) user. Everything it needs
# root for (system packages, /opt/ai-stack, systemd, swap) is run through sudo.

set -euo pipefail

PREFIX="/opt/ai-stack"
BIN_DIR="$PREFIX/bin"
VERSIONS_FILE="$PREFIX/versions.txt"
STACK_CONF="$PREFIX/stack.conf"

# User-owned source and build trees; these never require root.
SOURCE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ai-stack/src"
BUILD_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ai-stack/build"

DATA_DIR="${DATA_DIR:-/var/lib/llama-swap}"
CONFIG_DIR="$DATA_DIR/config"
MODEL_DIR="$DATA_DIR/models"

SWAP_SIZE="${SWAP_SIZE:-8G}"
NO_SWAP="${NO_SWAP:-0}"
BUILD_JOBS_ARG=""

LLAMA_SWAP_DIR="$SOURCE_DIR/llama-swap"

TMPDIR="$(mktemp -d)"
TEMP_PACKAGES=()
TEMP_SWAPFILE=""

# Single EXIT hook. Functions used for cleanup may not be defined yet when the
# script bails during early arg parsing, hence the declare -F guards.
on_exit() {
    rm -rf "$TMPDIR"
    if declare -F cleanup_temporary_swap >/dev/null; then
        cleanup_temporary_swap
    fi
    if declare -F cleanup_build_dependencies >/dev/null; then
        cleanup_build_dependencies
    fi
}

trap on_exit EXIT

################################################################################
# Colors + messaging
################################################################################

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}==>${NC} $*"; }
note()  { echo -e "${CYAN}   $*${NC}"; }
ok()    { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}==>${NC} $*"; }
die()   { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

# Never run the installer itself as root. Privileged actions go through sudo.
if [[ $EUID -eq 0 ]]; then
    die "Do not run this installer with sudo. Run it as a normal user."
fi

as_root() {
    sudo "$@"
}

require_sudo() {
    sudo -v
}

################################################################################
# Usage / CLI parsing
################################################################################

SELECTED_COMPONENTS=()
USE_ALL_ARG=""
AUTO_YES=0
RECONFIGURE=0

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [OPTIONS]

Compile and install the llama-swap AI stack from source. On first run you are
prompted to choose which components to install and which compute backend each
uses. Choices are saved to $STACK_CONF and reused on later runs.

Options:
  --data-dir DIR    Data/config/model directory. Default: $DATA_DIR
  --backend B       Force every backend to B (cuda, vulkan, hip, metal,
                    sycl, cpu). Skips interactive backend prompts.
                    Missing dev toolchains (CUDA toolkit, Vulkan dev tools)
                    are installed automatically when the backend relies on
                    them.
  --component NAME  Add a component to install. May be repeated.
                    Choices: llama, ik-llama, sd, whisper, kokoro,
                             crispasr, acestep, audio
  --kokoro-device D  Kokoro device: gpu, gpu-cu128, cpu, rocm (default auto).
  --cuda-archs AR   CUDA architectures for CUDA builds (default native).
  --jobs N          Number of parallel build jobs (default: auto by RAM, cap nproc).
  --swap-size SIZE  Swap file size offered by the low-memory prompt (default
                    ${SWAP_SIZE}, e.g. 8G).
  --no-swap          Never create or prompt about swap files.
  -y, --yes         Skip all prompts, using stored config + defaults.
  --reconfigure     Re-ask component and backend questions, even if a saved
                    config exists. Without this flag, an existing
                    $STACK_CONF is reused as-is.
  --uninstall       Remove installed AI software.
  --purge-data      Also delete the data directory (with --uninstall).
  -h, --help        Show this help and exit.

Examples:
  $(basename "$0")                     # use saved config, or first-run wizard
  $(basename "$0") --reconfigure       # change components or backends
  $(basename "$0") --backend vulkan
  $(basename "$0") --component llama --component whisper --backend cpu
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-dir)
            [[ $# -lt 2 ]] && die "--data-dir requires a directory"
            DATA_DIR="$2"; CONFIG_DIR="$DATA_DIR/config"; MODEL_DIR="$DATA_DIR/models"
            shift 2 ;;
        --backend)
            [[ $# -lt 2 ]] && die "--backend requires a value"
            USE_ALL_ARG="$2"; shift 2 ;;
        --component)
            [[ $# -lt 2 ]] && die "--component requires a name"
            SELECTED_COMPONENTS+=("$2"); shift 2 ;;
        --kokoro-device)
            [[ $# -lt 2 ]] && die "--kokoro-device requires a value"
            KOKORO_DEVICE="$2"; KOKORO_DEVICE_ARG=1; shift 2 ;;
        --cuda-archs)
            [[ $# -lt 2 ]] && die "--cuda-archs requires a value"
            CUDA_ARCHS="$2"; CUDA_ARCHS_ARG=1; shift 2 ;;
        --jobs)
            [[ $# -lt 2 ]] && die "--jobs requires a number"
            BUILD_JOBS_ARG="$2"; shift 2 ;;
        --swap-size)
            [[ $# -lt 2 ]] && die "--swap-size requires a size"
            SWAP_SIZE="$2"; shift 2 ;;
        --no-swap)
            NO_SWAP=1; shift ;;
        -y|--yes)
            AUTO_YES=1; shift ;;
        --reconfigure)
            RECONFIGURE=1; shift ;;
        --uninstall)
            UNINSTALL=1; shift ;;
        --purge-data)
            PURGE_DATA=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            die "Unknown option: $1 (try --help)" ;;
    esac
done

################################################################################
# Component registry
################################################################################
#
# Each component knows:
#   dir        - source directory (relative to SOURCE_DIR)
#   targets    - cmake targets to build
#   bins       - binaries copied from build/bin/ -> installed under PREFIX/<name>/
#   links      - (bin -> symlink name) pairs created in BIN_DIR
#   cmake_args - extra common cmake args
#   backends   - space-separated list of supported backend keys

# Per-component data lookups. Each cmake component provides:
#   dir      - source directory (relative to SOURCE_DIR)
#   targets  - cmake targets to build
#   bins     - binaries copied from build/ -> install PREFIX/<dir>/
#   links    - space-separated "bin link bin link ..." pairs for BIN_DIR
#   backends - space-separated list of supported backend keys
component_dir() {
    case "$1" in
        llama) echo "llama.cpp";; ik-llama) echo "ik_llama.cpp";;
        sd) echo "stable-diffusion.cpp";; whisper) echo "whisper.cpp";;
        acestep) echo "acestep.cpp";; audio) echo "audio.cpp";;
        crispasr) echo "CrispASR";; kokoro) echo "Kokoro-FastAPI";;
        llama-swap) echo "llama-swap";;
    esac
}

repo_url() {
    case "$1" in
        llama)     echo "https://github.com/ggml-org/llama.cpp" ;;
        ik-llama)  echo "https://github.com/ikawrakow/ik_llama.cpp" ;;
        sd)        echo "https://github.com/leejet/stable-diffusion.cpp" ;;
        whisper)   echo "https://github.com/ggml-org/whisper.cpp" ;;
        acestep)   echo "https://github.com/ServeurpersoCom/acestep.cpp" ;;
        audio)     echo "https://github.com/0xShug0/audio.cpp" ;;
        crispasr)  echo "https://github.com/CrispStrobe/CrispASR" ;;
        kokoro)    echo "https://github.com/remsky/Kokoro-FastAPI" ;;
        llama-swap) echo "https://github.com/mostlygeek/llama-swap" ;;
        *) return 1 ;;
    esac
}

ensure_source_repo() {
    local name="$1" url="$2"
    local dir="$SOURCE_DIR/$(component_dir "$name")"
    mkdir -p "$SOURCE_DIR"

    if [[ -f "$dir/.git/HEAD" ]]; then
        return 0
    fi
    if [[ -e "$dir" && -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
        warn "Source dir $dir exists but is not a git checkout; leaving it as-is"
        return 1
    fi

    info "Cloning $name sources from $url..."
    rm -rf "$dir"
    git clone "$url" "$dir" || die "Failed to clone $name from $url"
}

ensure_source_repos() {
    local name url
    for name in "${INSTALL_LIST[@]}"; do
        url="$(repo_url "$name" || true)"
        [[ -n "$url" ]] || continue
        ensure_source_repo "$name" "$url"
    done
}
component_targets() {
    case "$1" in
        llama) echo "llama-cli llama-server llama-tts llama-bench";;
        ik-llama) echo "llama-server";;
        sd) echo "sd-cli sd-server";;
        whisper) echo "whisper-cli whisper-server";;
        acestep) echo "ace-server";;
        audio) echo "audiocpp_cli audiocpp_server";;
        crispasr) echo "crispasr-cli crispasr-server";;
    esac
}
component_bins() {
    case "$1" in
        llama) echo "llama-cli llama-server llama-tts llama-bench";;
        ik-llama) echo "llama-server";;
        sd) echo "sd-cli sd-server";;
        whisper) echo "whisper-cli whisper-server";;
        acestep) echo "ace-server";;
        audio) echo "audiocpp_cli audiocpp_server";;
        crispasr) echo "crispasr crispasr-server";;
    esac
}
component_links() {
    # output "bin link bin link ..." for BIN_DIR symlinks
    case "$1" in
        llama) echo "llama-cli llama-cli llama-server llama-server llama-tts llama-tts llama-bench llama-bench";;
        ik-llama) echo "llama-server ik-llama-server";;
        sd) echo "sd-cli sd-cli sd-server sd-server";;
        whisper) echo "whisper-cli whisper-cli whisper-server whisper-server";;
        acestep) echo "ace-server ace-server";;
        audio) echo "audiocpp_cli audiocpp_cli audiocpp_server audiocpp_server";;
        crispasr) echo "crispasr crispasr crispasr-server crispasr-server";;
        kokoro) echo "kokoro-fastapi kokoro-fastapi";;
    esac
}
component_backends() {
    case "$1" in
        llama) echo "cuda vulkan hip metal sycl cpu";;
        ik-llama) echo "cuda vulkan cpu";;
        sd) echo "cuda vulkan hip metal sycl cpu";;
        whisper) echo "cuda vulkan hip metal sycl cpu";;
        acestep) echo "cuda vulkan hip metal sycl cpu";;
        audio) echo "cuda vulkan hip metal cpu";;
        crispasr) echo "cuda vulkan hip metal sycl cpu";;
    esac
}

# All selectable components
ALL_COMPONENTS=(llama ik-llama sd whisper kokoro crispasr acestep audio)

# Map component -> human description
COMPONENT_DESC=(
    "llama"     "llama.cpp (main LLM engine, llama-server + tools)"
    "ik-llama"  "ik_llama.cpp (alternative llama-server build)"
    "sd"        "stable-diffusion.cpp (image generation, sd-server + sd-cli)"
    "whisper"   "whisper.cpp (speech-to-text, whisper-server + whisper-cli)"
    "kokoro"    "Kokoro-FastAPI (text-to-speech, Python FastAPI service)"
    "crispasr"  "CrispASR (speech-to-text, crispasr-server)"
    "acestep"   "acestep.cpp (audio, ace-server)"
    "audio"     "audio.cpp (audio, TTS/ASR/audio OpenAI-compatible, audiocpp_server)"
)

# Backends that are always offered, + hardware-dependent availability
PRIORITY_BACKENDS="cuda vulkan cpu"
EXTRA_BACKENDS="hip metal sycl"

################################################################################
# Backend detection
################################################################################

uname_s="$(uname -s)"

# --- GPU detection -------------------------------------------------------
has_lspci_gpu() {
    command -v lspci >/dev/null 2>&1 || return 1
    local line
    line="$(lspci 2>/dev/null | grep -iE 'vga|3d' | grep -i "$1")"
    [[ -n "$line" ]]
}
has_nvidia_gpu() {
    command -v nvidia-smi >/dev/null 2>&1 && return 0
    has_lspci_gpu nvidia
}
has_amd_gpu()   { has_lspci_gpu 'amd|radeon'; }
has_intel_gpu() { has_lspci_gpu 'intel'; }

detect_gpus() {
    local g=""
    has_nvidia_gpu && g="$g nvidia"
    has_amd_gpu    && g="$g amd"
    has_intel_gpu  && g="$g intel"
    [[ -n "$g" ]] || g=" (none detected)"
    echo "$g"
}

# A backend is "ready" only when its full build toolchain is installed.
has_cuda()  { command -v nvcc >/dev/null 2>&1 || [[ -x /usr/local/cuda/bin/nvcc ]]; }
has_vulkan(){ [[ -f /usr/include/vulkan/vulkan.h ]] && command -v glslc >/dev/null 2>&1 && \
              { ldconfig -p 2>/dev/null | grep -q 'libvulkan\.so' || [[ -e /usr/lib/x86_64-linux-gnu/libvulkan.so ]]; }; }
has_hip()   { command -v hipcc >/dev/null 2>&1; }
has_metal() { [[ "$uname_s" == "Darwin" ]]; }
has_sycl()  { command -v icpx >/dev/null 2>&1 || command -v syclcc >/dev/null 2>&1; }

# Backends whose build toolchain is already installed on this machine.
detect_backends() {
    local b="cpu"
    has_cuda    && b="$b cuda"
    has_vulkan  && b="$b vulkan"
    has_hip     && b="$b hip"
    has_metal   && b="$b metal"
    has_sycl    && b="$b sycl"
    echo "$b"
}

# Should we offer this backend in the menus, even if its toolchain is not yet
# installed? (Selecting it triggers an on-the-spot toolchain install.)
backend_offered() {
    case "$1" in
        cpu)     return 0 ;;
        vulkan)  [[ "$uname_s" != "Darwin" ]] ;;
        cuda)    has_nvidia_gpu || has_cuda ;;
        hip)     has_amd_gpu || has_hip ;;
        metal)   [[ "$uname_s" == "Darwin" ]] ;;
        sycl)    has_sycl || has_intel_gpu ;;
        *)       return 1 ;;
    esac
}

# Short human status for a backend, shown next to it in the menus.
backend_note() {
    case "$1" in
        cpu)    echo "always available" ;;
        vulkan) if has_vulkan; then echo "ready"; else echo "will install Vulkan dev tools"; fi ;;
        cuda)   if has_cuda; then echo "ready"; else
                    local dm
                    dm=$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n1)
                    if [[ -n "${dm:-}" ]]; then echo "NVIDIA GPU (driver supports CUDA $dm; will install toolkit)";
                    else echo "NVIDIA GPU found; will install CUDA toolkit"; fi
                fi ;;
        hip)    if has_hip; then echo "ready"; else echo "AMD GPU found; will install HIP/ROCm"; fi ;;
        metal)  echo "macOS only" ;;
        sycl)   if has_sycl; then echo "ready"; else echo "Intel GPU found; will install oneAPI"; fi ;;
        *)      echo "" ;;
    esac
}

# Pick the most capable backend given a space-separated list of available ones.
pick_best() {
    local avail="$1"
    for b in cuda vulkan hip metal sycl cpu; do
        [[ " $avail " == *" $b "* ]] && { echo "$b"; return; }
    done
    echo "cpu"
}

detect_cuda_archs() {
    if [[ -n "${CUDA_ARCHS:-}" ]]; then
        echo "$CUDA_ARCHS"
    elif [[ -n "${CMAKE_CUDA_ARCHITECTURES:-}" ]]; then
        echo "$CMAKE_CUDA_ARCHITECTURES"
    else
        echo "native"
    fi
}

################################################################################
# Config load/save
################################################################################

# default values
BACKEND_LLAMA=auto
BACKEND_IK_LLAMA=auto
BACKEND_SD=auto
BACKEND_WHISPER=auto
BACKEND_ACESTEP=auto
BACKEND_AUDIO=auto
BACKEND_CRISPASR=auto
KOKORO_DEVICE="${KOKORO_DEVICE:-auto}"
CUDA_ARCHS="${CUDA_ARCHS:-native}"

CONFIG_LOADED=0

load_config() {
    if [[ ! -f "$STACK_CONF" ]]; then return; fi
    CONFIG_LOADED=1
    # TODO: parse $STACK_CONF with a proper key=value parser instead of
    # sourcing it (values are currently trusted shell assignments).
    # shellcheck disable=SC1090
    source "$STACK_CONF"
}

save_config() {
    as_root mkdir -p "$PREFIX"
    # TODO: replace sourcing-based config with a proper key=value parser
    # shellcheck disable=SC2028
    as_root tee "$STACK_CONF" >/dev/null <<EOF
# Generated by install-ai-stack.sh
INSTALL_COMPONENTS="${INSTALL_LIST[*]}"
BACKEND_LLAMA=$BACKEND_LLAMA
BACKEND_IK_LLAMA=$BACKEND_IK_LLAMA
BACKEND_SD=$BACKEND_SD
BACKEND_WHISPER=$BACKEND_WHISPER
BACKEND_ACESTEP=$BACKEND_ACESTEP
BACKEND_AUDIO=$BACKEND_AUDIO
BACKEND_CRISPASR=$BACKEND_CRISPASR
KOKORO_DEVICE=$KOKORO_DEVICE
CUDA_ARCHS=$CUDA_ARCHS
EOF
}

################################################################################
# Dependency checks
################################################################################

ensure_runtime_dependencies() {
    local missing=()
    for c in curl jq tar unzip; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    # libssl-dev gives curl OpenSSL support on minimal images where curl is
    # present but lacks TLS, and is needed by SSL-using builds. Check it even
    # when curl itself is already installed.
    dpkg -s libssl-dev >/dev/null 2>&1 || missing+=(libssl-dev)
    [[ ${#missing[@]} -eq 0 ]] && return
    info "Installing runtime dependencies..."
    as_root apt-get update
    as_root apt-get install -y "${missing[@]}"
}

# Node.js is required for the llama-swap web UI. Ubuntu's nodejs is often
# too old (v18/v20); we guarantee Node 24+ by removing the distro package and
# installing the official Node via nvm.
# Enable the pnpm shims (sd-server's webui frontend is a pnpm project and is
# built during `cmake --build`). pnpm ships with Node via corepack. We write
# the shims into the user's writable ~/.local/bin (the nvm node dir is often
# root-owned, which makes `corepack enable` fail there), then symlink them
# into /usr/local/bin like node/npm/npx.
enable_pnpm() {
    # Best-effort/optional: pnpm is only needed to build the sd-server webui,
    # so a missing/broken Corepack or pnpm must never abort the installer
    # under `set -e`. Always return success.
    if ! command -v corepack >/dev/null 2>&1; then
        warn "Corepack is not available; skipping pnpm setup."
        return 0
    fi
    mkdir -p "$HOME/.local/bin"
    if ! corepack enable --install-directory "$HOME/.local/bin" pnpm 2>/dev/null; then
        warn "corepack enable pnpm failed; skipping pnpm setup."
        return 0
    fi
    for c in pnpm pnpx; do
        [[ -e "$HOME/.local/bin/$c" ]] && as_root ln -sf "$HOME/.local/bin/$c" "/usr/local/bin/$c"
    done
    if command -v pnpm >/dev/null 2>&1; then
        ok "pnpm ready: $(pnpm -v 2>/dev/null)"
    else
        warn "pnpm not available (corepack enable pnpm failed)."
    fi
    return 0
}

ensure_nodejs() {
    # If a current, recent node is already on PATH, nothing to do.
    if command -v node >/dev/null 2>&1; then
        local cur
        cur="$(node -v 2>/dev/null)"
        cur="${cur#v}"
        local major="${cur%%.*}"
        if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 24 )); then
            ok "Node.js already at $cur (>= 24 required)"
            enable_pnpm
            return 0
        fi
        warn "Node.js $cur is too old (need >= 24); replacing with official Node 24 via nvm."
    fi

    # Remove Ubuntu's nodejs/npm if present so the official build wins.
    if dpkg -s nodejs >/dev/null 2>&1 || command -v npm >/dev/null 2>&1; then
        warn "Removing Ubuntu's nodejs/npm (too old / conflicts with official Node)..."
        as_root apt-get purge -y nodejs npm 2>/dev/null || true
        as_root apt-get autoremove -y 2>/dev/null || true
    fi

    # Install nvm under the real user's home (this script runs as the user).
    export NVM_DIR="$HOME/.nvm"
    mkdir -p "$NVM_DIR"

    if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
        info "Installing nvm into $NVM_DIR..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.7/install.sh | bash
    fi

    # shellcheck source=/dev/null
    \. "$NVM_DIR/nvm.sh"

    info "Installing Node.js 24 via nvm..."
    # nvm is incompatible with a set PREFIX env var, which this script uses
    # for its own /opt/ai-stack prefix. Unset it for the nvm operations.
    local _saved_prefix="${PREFIX:-}"
    unset PREFIX
    nvm install 24
    nvm alias default 24
    PREFIX="${_saved_prefix}"

    # Make node available system-wide so running shells (and services) see it.
    local node_bin
    node_bin="$(nvm which 24 2>/dev/null)"
    node_bin="${node_bin%/*}"
    if [[ -n "$node_bin" && -d "$node_bin" ]]; then
        for c in node npm npx; do
            [[ -e "$node_bin/$c" ]] && as_root ln -sf "$node_bin/$c" "/usr/local/bin/$c"
        done
    fi

    enable_pnpm

    if command -v node >/dev/null 2>&1; then
        ok "Node.js ready: $(node -v) / npm $(npm -v)"
    else
        export PATH="$node_bin:$PATH"
        ok "Node.js ready (via $node_bin): $(node -v) / npm $(npm -v)"
    fi
}

ensure_build_dependencies() {
    TEMP_PACKAGES=()
    local missing=()

    for p in git cmake build-essential pkg-config; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing build dependencies: ${missing[*]}"
        as_root apt-get update
        as_root apt-get install -y "${missing[@]}"
        TEMP_PACKAGES=("${missing[@]}")
    fi
}

cleanup_build_dependencies() {
    [[ ${#TEMP_PACKAGES[@]} -eq 0 ]] && return
    info "Removing temporary build dependencies..."
    as_root apt-get purge -y "${TEMP_PACKAGES[@]}" || true
    as_root apt-get autoremove -y || true
    # Make this idempotent: it may be called explicitly at end of main() and
    # again by the EXIT trap. Clearing avoids a second "not installed" purge.
    TEMP_PACKAGES=()
}

# Install per-backend dev toolchains chosen during backend selection.
# These are large, so they are *kept* (not uninstalled on exit). Unavailable
# backends fall back per-component to cpu with a warning.
ensure_backend_dependencies() {
    local c varname b seen=() fallback=()

    for c in "${INSTALL_LIST[@]}"; do
        [[ "$c" == "kokoro" ]] && continue
        varname="$(backend_varname "$c")"
        b="${!varname:-auto}"
        [[ "$b" == "auto" ]] && b="$(pick_best "$(available_backends_for "$c")")"
        [[ " ${seen[*]} " == *" $b "* ]] || seen+=("$b")
    done

    for b in "${seen[@]}"; do
        case "$b" in
            cuda)
                if ! has_cuda; then
                    local driver_cuda_max
                    driver_cuda_max=$(
                        nvidia-smi 2>/dev/null |
                        sed -n 's/.*CUDA Version:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' |
                        head -n1
                    )
                    local cuda_hint="(driver supports up to CUDA ${driver_cuda_max:-unknown})"
                    if [[ "$AUTO_YES" != 1 ]] && \
                       ! confirm "CUDA toolkit is not installed. Install ${cuda_hint}?"; then
                        fallback+=("$b"); continue
                    fi
                    ensure_cuda_toolkit || fallback+=("$b")
                fi ;;
            vulkan)
                has_vulkan || ensure_vulkan_dev || fallback+=("$b") ;;
            hip)
                if ! has_hip; then
                    if [[ "$AUTO_YES" != 1 ]] && \
                       ! confirm "HIP/ROCm toolchain is not installed. Attempt to install it now?"; then
                        fallback+=("$b"); continue
                    fi
                    ensure_hip_toolchain || fallback+=("$b")
                fi ;;
            sycl)
                if ! has_sycl; then
                    warn "Intel oneAPI is not auto-installed by this script."
                    fallback+=("$b")
                fi ;;
        esac
    done

    if [[ ${#fallback[@]} -gt 0 ]]; then
        echo
        for c in "${INSTALL_LIST[@]}"; do
            [[ "$c" == "kokoro" ]] && continue
            varname="$(backend_varname "$c")"
            b="${!varname:-auto}"
            [[ " ${fallback[*]} " == *" $b "* ]] || continue
            eval "$varname=cpu"
            warn "$c: backend '$b' unavailable; falling back to cpu"
        done
        echo
    fi
}

ensure_vulkan_dev() {
    info "Installing Vulkan development packages..."
    as_root apt-get install -y libvulkan-dev glslang-tools spirv-tools spirv-headers
    as_root ldconfig
    has_vulkan
}

ensure_cuda_toolkit() {
    has_cuda && return 0

    # Detect driver's maximum supported CUDA version
    local driver_cuda_max
    driver_cuda_max=$(
        nvidia-smi 2>/dev/null |
        sed -n 's/.*CUDA Version:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' |
        head -n1
    )
    [[ -n "$driver_cuda_max" ]] || return 1

    # Remove Ubuntu's conflicting nvidia-cuda-toolkit if present
    if dpkg -s nvidia-cuda-toolkit >/dev/null 2>&1; then
        warn "Removing Ubuntu's nvidia-cuda-toolkit (conflicts with NVIDIA's toolkit)..."
        as_root apt-get purge -y nvidia-cuda-toolkit nvidia-cuda-dev 2>/dev/null || true
    fi

    # Ensure NVIDIA CUDA repo is present so versioned packages are discoverable
    local keyring=/usr/share/keyrings/cuda-archive-keyring.gpg
    if [[ ! -f "$keyring" ]]; then
        local repo="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64"
        local deb=/tmp/cuda-keyring.deb
        curl -fsSL "$repo/cuda-keyring_1.1-1_all.deb" -o "$deb" || return 1
        as_root dpkg -i "$deb" >/dev/null 2>&1 || { rm -f "$deb"; return 1; }
        rm -f "$deb"
    fi
    as_root apt-get update

    # Recommended CUDA toolkit versions (13.1 / 13.2 are known-problematic;
    # avoid them). 12.8 is the most stable.
    local good=(12-8 12-9 13-0 13-3)
    local candidates=() v comparable
    for v in "${good[@]}"; do
        comparable="${v/-/.}"
        dpkg --compare-versions "$comparable" le "$driver_cuda_max" || continue
        apt-cache show "cuda-toolkit-$v" >/dev/null 2>&1 && candidates+=("$v")
    done

    # Fallback for older GPUs / narrow repos: pick the highest compatible
    # while still avoiding the known-bad 13.1/13.2 versions.
    if [[ ${#candidates[@]} -eq 0 ]]; then
        candidates=($(
            apt-cache pkgnames 2>/dev/null |
            grep -E '^cuda-toolkit-[0-9]+-[0-9]+$' |
            grep -vE '^cuda-toolkit-(13-1|13-2)$' |
            sed 's/^cuda-toolkit-//' |
            sort -V |
            while read -r v; do
                comparable="${v/-/.}"
                dpkg --compare-versions "$comparable" le "$driver_cuda_max" && echo "$v"
            done || true
        ))
    fi
    [[ ${#candidates[@]} -gt 0 ]] || return 1

    local selected
    if [[ "$AUTO_YES" == 1 || ${#candidates[@]} -eq 1 ]]; then
        selected="${candidates[0]}"
        info "Selecting CUDA $selected (most stable option compatible with your driver)."
    else
        local opts=() label
        for v in "${candidates[@]}"; do
            case "$v" in
                12-8) label="12.8 - most stable (recommended)" ;;
                *)    label="${v/-/.}" ;;
            esac
            opts+=("$label")
        done
        local choice
        choice="$(menu_choice "Which CUDA toolkit version to install? (driver supports up to CUDA $driver_cuda_max):" "${opts[@]}")"
        selected="${choice%% *}"
        selected="${selected//./-}"
    fi

    local pkg="cuda-toolkit-$selected"
    info "Installing $pkg (compatible with driver CUDA $driver_cuda_max)..."
    as_root apt-get install -y --no-install-recommends "$pkg" || return 1

    export PATH="/usr/local/cuda/bin:$PATH"
    export CUDA_HOME="/usr/local/cuda"

    [[ -x /usr/local/cuda/bin/nvcc ]]
}

ensure_hip_toolchain() {
    info "Installing HIP/ROCm toolchain from Ubuntu repositories..."
    as_root apt-get install -y --no-install-recommends hipcc || return 1
    has_hip
}

################################################################################
# Prompt helpers
################################################################################

confirm() {
    local prompt="$1" default="${2:-n}"
    if [[ "$AUTO_YES" == 1 ]]; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi
    local ans
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy] ]]
}

menu_choice() {
    local prompt="$1"; shift
    local opts=("$@")
    while true; do
        echo "$prompt" >&2
        for i in "${!opts[@]}"; do
            echo "  $((i+1)). ${opts[$i]}" >&2
        done
        read -r -p "Choice: " ans >&2
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then
            echo "${opts[$((ans-1))]}"
            return
        fi
        warn "Please choose a number between 1 and ${#opts[@]}"
    done
}

multi_choice() {
    local prompt="$1"; shift
    local opts=("$@")
    local chosen=()
    echo "$prompt" >&2
    for i in "${!opts[@]}"; do
        echo "  $((i+1)). ${opts[$i]}" >&2
    done
    echo "  a. All" >&2
    echo "  n. None" >&2
    read -r -p "Select (comma-separated numbers, a for all, n for none): " ans >&2
    [[ "$ans" == "a" || "$ans" == "A" ]] && { printf '%s\n' "${opts[@]}"; return; }
    [[ "$ans" == "n" || "$ans" == "N" ]] && return
    IFS=',' read -r -ra parts <<< "$ans"
    for p in "${parts[@]}"; do
        p="$(echo "$p" | tr -d ' ')"
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#opts[@]} )); then
            chosen+=("${opts[$((p-1))]}")
        else
            warn "Ignoring invalid selection: $p"
        fi
    done
    printf '%s\n' "${chosen[@]}"
}

################################################################################
# Version helpers (kept for compatibility, minimal use)
################################################################################

get_installed_version() {
    grep "^${1}=" "$VERSIONS_FILE" 2>/dev/null | cut -d= -f2 || true
}

set_installed_version() {
    local key="$1" value="$2" tmp="$TMPDIR/versions.tmp"
    grep -v "^${key}=" "$VERSIONS_FILE" > "$tmp" 2>/dev/null || true
    echo "${key}=${value}" >> "$tmp"
    as_root install -m644 "$tmp" "$VERSIONS_FILE"
}

################################################################################
# Component selection
################################################################################

install_components() {
    if [[ ${#SELECTED_COMPONENTS[@]} -gt 0 ]]; then
        INSTALL_LIST=("${SELECTED_COMPONENTS[@]}")
        return
    fi
    # Non-interactive (-y): reuse saved components when present, else the full stack.
    if [[ "$AUTO_YES" == 1 ]]; then
        if [[ "$CONFIG_LOADED" == 1 && -n "${INSTALL_COMPONENTS:-}" ]]; then
            INSTALL_LIST=($INSTALL_COMPONENTS)
        else
            INSTALL_LIST=("${ALL_COMPONENTS[@]}")
        fi
        return
    fi
    # Reuse the saved config unless the user asked to reconfigure.
    if [[ "$CONFIG_LOADED" == 1 && -n "${INSTALL_COMPONENTS:-}" && "$RECONFIGURE" == 0 ]]; then
        INSTALL_LIST=($INSTALL_COMPONENTS)
        note "Installing saved components: ${INSTALL_LIST[*]} (use --reconfigure to change)"
        echo
        return
    fi

    echo "=== Component selection ==="
    echo
    echo "Which components would you like to install?"
    echo "  (llama-swap itself is always installed)"
    echo
    local desc opts
    desc=()
    opts=()
    for c in "${ALL_COMPONENTS[@]}"; do
        local d=""
        local i
        for (( i=0; i<${#COMPONENT_DESC[@]}; i+=2 )); do
            if [[ "${COMPONENT_DESC[$i]}" == "$c" ]]; then
                d="${COMPONENT_DESC[$((i+1))]}"
                break
            fi
        done
        desc+=("$c - $d")
        opts+=("$c")
    done
    local selected
    mapfile -t selected < <(multi_choice "Select components:" "${desc[@]}")
    # multi_choice returns the full display label ("llama - <desc>");
    # reduce each to its leading component key.
    INSTALL_LIST=()
    for s in "${selected[@]}"; do
        INSTALL_LIST+=("${s%% -*}")
    done
    [[ ${#INSTALL_LIST[@]} -eq 0 ]] && die "No components selected; nothing to install."
    echo
}

################################################################################
# Backend selection
################################################################################

backend_varname() {
    case "$1" in
        llama)   echo "BACKEND_LLAMA" ;;
        ik-llama) echo "BACKEND_IK_LLAMA" ;;
        sd)      echo "BACKEND_SD" ;;
        whisper) echo "BACKEND_WHISPER" ;;
        acestep) echo "BACKEND_ACESTEP" ;;
        audio)   echo "BACKEND_AUDIO" ;;
        crispasr) echo "BACKEND_CRISPASR" ;;
        kokoro)  echo "KOKORO_DEVICE" ;;
    esac
}

# Intersect a component's supported backends with what we can offer here
# (installed toolchains AND installable ones, e.g. CUDA on an NVIDIA box).
available_backends_for() {
    local c="$1" supported result b
    supported="$(component_backends "$c")"
    result=""
    for b in $supported; do
        backend_offered "$b" && result="$result $b"
    done
    # kokoro is a pip extra, no GGML backend dependency
    [[ "$c" == "kokoro" ]] && result=" gpu gpu-cu128 cpu rocm"
    echo "$result"
}

select_backends() {
    local components=("$@")
    local show_all

    # Reuse saved backends unless we were asked to reconfigure interactively.
    if [[ "$CONFIG_LOADED" == 1 && "$RECONFIGURE" == 0 && "$AUTO_YES" == 0 ]] \
       && [[ -z "${USE_ALL_ARG:-}" ]]; then
        note "Reusing saved backend choices from $STACK_CONF (use --reconfigure to change)."
        echo
        return
    fi

    echo "=== Backend selection ==="
    echo
    note "Detected GPUs:$(detect_gpus)"
    note "Build-ready backends: $(detect_backends)"
    echo

    # Offer "use one backend for all" shortcut for the meaty cmake components.
    local cmake_components=()
    for c in "${components[@]}"; do
        [[ "$c" != "kokoro" ]] && cmake_components+=("$c")
    done

    show_all="${USE_ALL_ARG:-}"

    if [[ -z "$show_all" && "$AUTO_YES" == 0 && ${#cmake_components[@]} -gt 1 ]]; then
        if confirm "Use the same backend for all components?"; then
            local opts b supported
            opts=()
            for b in $PRIORITY_BACKENDS $EXTRA_BACKENDS; do
                backend_offered "$b" || continue
                supported=1
                for c in "${cmake_components[@]}"; do
                    [[ " $(component_backends "$c") " == *" $b "* ]] || supported=0
                done
                [[ $supported == 1 ]] || continue
                opts+=("$b - $(backend_note "$b")")
            done
            [[ ${#opts[@]} -eq 0 ]] && opts=("cpu - always available")
            show_all="$(menu_choice "Choose a backend for all components:" "${opts[@]}")"
            show_all="${show_all%% - *}"
            echo
        fi
    fi

    local c varname current opts b avail
    for c in "${components[@]}"; do
        varname="$(backend_varname "$c")"
        current="${!varname:-auto}"
        avail="$(available_backends_for "$c")"

        if [[ -n "$show_all" ]]; then
            if [[ "$c" == "kokoro" ]]; then
                current="$(kokoro_device_for_backend "$show_all")"
            else
                # only force a backend this component supports, and that we can
                # offer here (the toolchain gets installed automatically if missing)
                if [[ " $avail " != *" $show_all "* ]]; then
                    warn "$c does not support/offer backend '$show_all'; selecting best available."
                    current="$(pick_best "$avail")"
                else
                    current="$show_all"
                fi
            fi
            eval "$varname=$current"
            ok "$c -> $current"
            continue
        fi

        if [[ "$c" == "kokoro" ]]; then
            # not a GGML cmake backend; device is a pip extra
            if [[ "$current" != gpu && "$current" != gpu-cu128 && "$current" != cpu && "$current" != rocm ]]; then
                current="auto"
            fi
            if [[ "$AUTO_YES" == 0 ]]; then
                current="$(menu_choice "Device for kokoro (auto/gpu/gpu-cu128/cpu/rocm): " auto gpu gpu-cu128 cpu rocm)"
            fi
        else
            opts=()
            for b in $PRIORITY_BACKENDS $EXTRA_BACKENDS; do
                [[ " $avail " == *" $b "* ]] && opts+=("$b - $(backend_note "$b")")
            done
            [[ " $avail " == *" $current "* ]] || current="$(pick_best "$avail")"
            if [[ "$AUTO_YES" == 0 ]]; then
                current="$(menu_choice "Backend for $c: " "${opts[@]}")"
                current="${current%% - *}"
            fi
        fi
        eval "$varname=$current"
        ok "$c -> $current"
    done
}

kokoro_device_for_backend() {
    case "$1" in
        cuda) echo "gpu" ;;
        hip)  echo "rocm" ;;
        cpu)  echo "cpu" ;;
        *)    echo "auto" ;;
    esac
}

################################################################################
# Build helpers
################################################################################

ensure_submodules() {
    local src="$1"
    [[ -f "$src/.gitmodules" ]] || return 0
    [[ -d "$src/.git" ]] || return 0
    info "Ensuring git submodules in $(basename "$src")..."
    git -C "$src" submodule update --init --recursive --depth=1 2>/dev/null || \
        warn "Submodule update skipped/failed for $(basename "$src") (may still build if vendored deps present)."
}

# cmake args for a given backend. Two forms:
#   single flag style (GGML_) for llama/ik/whisper/crispasr/acestep
#   sd style (SD_) for stable-diffusion
#   engine style (ENGINE_) for audio.cpp
ggml_backend_flags() {
    local backend="$1" style="$2"
    case "$backend" in
        cpu)    return 0 ;;                      # no flag, ggml CPU is default
        cuda)   case "$style" in
                    sd)  echo "-DSD_CUDA=ON -DGGML_CUDA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON" ;;
                    audio) echo "-DENGINE_ENABLE_CUDA=ON -DGGML_CUDA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON" ;;
                    *)   echo "-DGGML_CUDA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON" ;;
                esac ;;
        vulkan) case "$style" in
                    sd)  echo "-DSD_VULKAN=ON -DGGML_VULKAN=ON" ;;
                    audio) echo "-DENGINE_ENABLE_VULKAN=ON -DGGML_VULKAN=ON" ;;
                    *)   echo "-DGGML_VULKAN=ON" ;;
                esac ;;
        hip)    case "$style" in
                    sd)  echo "-DSD_HIPBLAS=ON -DGGML_HIP=ON" ;;
                    audio) echo "-DENGINE_ENABLE_HIP=ON -DGGML_HIP=ON" ;;
                    *)   echo "-DGGML_HIP=ON" ;;
                esac ;;
        metal)  case "$style" in
                    sd)  echo "-DSD_METAL=ON -DGGML_METAL=ON" ;;
                    audio) echo "-DENGINE_ENABLE_METAL=ON -DGGML_METAL=ON" ;;
                    *)   echo "-DGGML_METAL=ON" ;;
                esac ;;
        sycl)   case "$style" in
                    sd)  echo "-DSD_SYCL=ON -DGGML_SYCL=ON" ;;
                    audio) echo "-DGGML_SYCL=ON" ;;   # raw only
                    *)   echo "-DGGML_SYCL=ON" ;;
                esac ;;
        *)      return 0 ;;
    esac
}

# Convert cmake type to a string of cmake -D options including cuda archs
backend_cmake_flags() {
    local backend="$1" style="$2" flags
    flags="$(ggml_backend_flags "$backend" "$style")"
    if [[ "$backend" == "cuda" ]]; then
        local archs
        archs="$(detect_cuda_archs)"
        flags="$flags -DCMAKE_CUDA_ARCHITECTURES=$archs"
        if [[ -x /usr/local/cuda/bin/nvcc ]]; then
            flags="$flags -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc"
        fi
        flags="$flags -DCMAKE_CUDA_FLAGS=-allow-unsupported-compiler"
    fi
    echo "$flags"
}

# CUDA linker flags must be passed as a single argv element (value contains a space).
cuda_linker_flags() {
    echo "-Wl,-rpath-link,/usr/local/cuda/lib64/stubs -lcuda"
}

build_and_install() {
    # $1 = component key
    local c="$1"

    local varname backend
    varname="$(backend_varname "$c")"
    backend="${!varname:-auto}"
    [[ "$backend" == "auto" ]] && backend="$(pick_best "$(detect_backends)")"

    local dir targets bins links_spec src
    dir="$(component_dir "$c")"
    targets="$(component_targets "$c")"
    bins="$(component_bins "$c")"
    links_spec="$(component_links "$c")"
    src="$SOURCE_DIR/$dir"

    info "Building $c ($dir) with backend: $backend"

    [[ -d "$src" ]] || die "Source directory not found for $c: $src"

    ensure_submodules "$src"

    local build_dir="$BUILD_DIR/$c"
    mkdir -p "$build_dir"
    local common_flags=(-DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON -DBUILD_SHARED_LIBS=OFF)

    # Avoid stale cmake cache from a previous backend run
    rm -rf "$build_dir/CMakeCache.txt" "$build_dir/CMakeFiles" 2>/dev/null || true

    # Mutually exclude other backends to prevent cache contamination
    [[ "$backend" == "cuda" ]]   && common_flags+=("-DGGML_VULKAN=OFF")
    [[ "$backend" == "vulkan" ]] && common_flags+=("-DGGML_CUDA=OFF")

    # style / special handling per component
    local extra=() style flags
    case "$c" in
        llama|ik-llama|whisper|acestep|crispasr)
            style="ggml"
            [[ "$c" == "whisper" ]] && extra+=(-DWHISPER_FFMPEG=ON)
            ;;
        sd)
            style="sd"
            extra+=(-DSD_BUILD_EXAMPLES=ON -DSD_SERVER_BUILD_FRONTEND=ON)
            ;;
        audio)
            style="audio"
            extra+=(
                -DAUDIOCPP_DEPLOYMENT_BUILD=ON
                -DAUDIOCPP_MODEL_SET=full
                -DENGINE_ENABLE_NATIVE_CPU=OFF
                -DENGINE_ENABLE_OPENMP=ON
                -DENGINE_BUILD_EXAMPLES=OFF
                -DENGINE_BUILD_TESTS=OFF
                -DENGINE_BUILD_WARMBENCH=OFF
            )
            ;;
        *) die "no build style for $c" ;;
    esac

    flags="$(backend_cmake_flags "$backend" "$style")"

    local cuda_linker=()
    if [[ "$backend" == "cuda" ]]; then
        cuda_linker=("-DCMAKE_EXE_LINKER_FLAGS=$(cuda_linker_flags)")
    fi

    info "cmake configure..."
    cmake -S "$src" -B "$build_dir" "${common_flags[@]}" "${extra[@]}" $flags "${cuda_linker[@]}"

    info "Building targets: $targets"
    cmake --build "$build_dir" --config Release -j"$BUILD_JOBS" --target $targets

    # Install binaries under $PREFIX (requires root)
    local inst="$PREFIX/$dir"
    as_root rm -rf "$inst"
    as_root mkdir -p "$inst"
    local i=0 pairs=()
    # links_spec is "bin link bin link ..."
    local blist
    blist=($bins)
    IFS=' ' read -r -a lpairs <<< "$links_spec"

    # Copy each built binary
    for b in $bins; do
        # find the actual binary. Some projects put outputs in build/bin,
        # others in build/ (acestep does).
        local found=""
        for cand in "$build_dir/bin/$b" "$build_dir/$b"; do
            if [[ -f "$cand" ]]; then found="$cand"; break; fi
        done
        [[ -n "$found" ]] || die "$c: built binary $b not found under $build_dir"
        as_root install -m755 "$found" "$inst/"
    done

    # Create symlinks in BIN_DIR per links_spec
    local k=0
    while [[ $k -lt ${#lpairs[@]} ]]; do
        local lbin="${lpairs[$k]}" lname="${lpairs[$((k+1))]}"
        make_link "$inst/$lbin" "$lname"
        k=$((k+2))
    done

    # copy shared libraries if any (whisper/sd/audio vendor ggml .so)
    copy_shlibs "$build_dir" "$inst"

    record_version "$c" "$src"
    ok "Installed $c (backend: $backend)"
}

copy_shlibs() {
    local build_dir="$1" inst="$2"
    local shlib_dir=""
    for d in "$build_dir/bin" "$build_dir"; do
        if find "$d" -maxdepth 1 -name '*.so*' -print -quit 2>/dev/null | grep -q .; then
            shlib_dir="$d"; break
        fi
    done
    [[ -z "$shlib_dir" ]] && return
    # copy only libggml / project-specific libs, keep out tiny support libs
    find "$shlib_dir" -maxdepth 1 \( -name 'libggml*.so*' -o -name 'libwhisper*.so*' -o -name 'libsd*.so*' -o -name 'libstable*.so*' -o -name 'libengine*.so*' -o -name 'libcrispasr*.so*' -o -name 'libacestep*.so*' \) -exec as_root cp -a {} "$inst/" \; 2>/dev/null || true
    if find "$inst" -name '*.so*' -print -quit 2>/dev/null | grep -q .; then
        # Register this install dir for the dynamic linker
        local conf=/etc/ld.so.conf.d/ai-stack.conf
        if ! grep -qxF "$inst" "$conf" 2>/dev/null; then
            echo "$inst" | as_root tee -a "$conf" >/dev/null
        fi
        as_root ldconfig 2>/dev/null || true
    fi
}

# Record the release this checkout is based on: exactly-on-tag, falling back to
# the nearest reachable tag, then the short commit hash. Release-based values
# change only when upstream ships a new tagged release, unlike a raw HEAD hash.
record_version() {
    local c="$1" src="$2"
    local ver=""
    ver="$(git -C "$src" describe --tags --exact-match 2>/dev/null || true)"
    [[ -z "$ver" ]] && ver="$(git -C "$src" describe --tags --abbrev=0 2>/dev/null || true)"
    [[ -z "$ver" ]] && ver="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    set_installed_version "$(tr 'a-z-' 'A-Z_' <<< "$c" | sed 's/-/_/g')" "$ver"
}

# True (0) when component $1 is already built at the current source version,
# so the rebuild can be skipped. Mirrors record_version's tag logic and is
# gated on --reconfigure, which forces a fresh build (e.g. after the user
# picks a different backend). Also requires the installed binary to exist on
# disk so a wiped $PREFIX still triggers a (re)install.
is_up_to_date() {
    [[ "$RECONFIGURE" == 1 ]] && return 1
    local c="$1" dir src
    dir="$(component_dir "$c")"
    src="$SOURCE_DIR/$dir"
    [[ -d "$src" ]] || return 1

    local key inst cur
    key="$(tr 'a-z-' 'A-Z_' <<< "$c" | sed 's/-/_/g')"
    inst="$(get_installed_version "$key" || true)"
    [[ -n "$inst" ]] || return 1

    cur="$(git -C "$src" describe --tags --exact-match 2>/dev/null || true)"
    [[ -z "$cur" ]] && cur="$(git -C "$src" describe --tags --abbrev=0 2>/dev/null || true)"
    [[ -z "$cur" ]] && cur="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || true)"
    [[ -n "$cur" && "$cur" == "$inst" ]] || return 1

    if [[ "$c" == "kokoro" ]]; then
        [[ -x "$src/.venv/bin/python" && -x "$BIN_DIR/kokoro-fastapi" ]] || return 1
        return 0
    fi

    local probe
    probe="$(component_bins "$c" | awk '{print $1}')"
    [[ -n "$probe" && -f "$PREFIX/$dir/$probe" ]] || return 1
    return 0
}

################################################################################
# Kokoro-FastAPI (Python)
################################################################################

install_kokoro() {
    local src="$SOURCE_DIR/Kokoro-FastAPI"
    [[ -d "$src" ]] || die "Kokoro-FastAPI source not found: $src"

    local device="${KOKORO_DEVICE:-auto}"
    if [[ "$device" == "auto" ]]; then
        if has_cuda; then device="gpu"; else device="cpu"; fi
    fi
    KOKORO_DEVICE="$device"

    info "Installing Kokoro-FastAPI (device: $device)"

    if ! command -v uv >/dev/null 2>&1; then
        info "Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
        command -v uv >/dev/null 2>&1 || die "uv install failed"
    fi

    # Required system packages for kokoro. espeak-ng is needed at runtime and is
    # installed persistently; python3-dev/python3-venv are build-only deps and
    # are tracked in TEMP_PACKAGES so cleanup_build_dependencies purges them.
    if ! command -v espeak-ng >/dev/null 2>&1; then
        info "Installing espeak-ng (runtime requirement)..."
        as_root apt-get update
        as_root apt-get install -y espeak-ng
    fi

    local kokoro_build_pkgs=()
    for p in python3-dev python3-venv; do
        dpkg -s "$p" >/dev/null 2>&1 || kokoro_build_pkgs+=("$p")
    done
    if [[ ${#kokoro_build_pkgs[@]} -gt 0 ]]; then
        info "Installing kokoro build-only dependencies: ${kokoro_build_pkgs[*]}"
        as_root apt-get update
        as_root apt-get install -y "${kokoro_build_pkgs[@]}"
        TEMP_PACKAGES+=("${kokoro_build_pkgs[@]}")
    fi

    local extra
    case "$device" in
        gpu)        extra="gpu" ;;
        gpu-cu128)  extra="gpu-cu128" ;;
        rocm)       extra="rocm" ;;
        cpu|*)      extra="cpu" ;;
    esac

    ( cd "$src" && uv sync --extra "$extra" --frozen 2>/dev/null || uv sync --extra "$extra" )

    [[ -x "$src/.venv/bin/python" ]] || die "Kokoro venv python not found after uv sync"

    # Fetch the model/tuner weights if not already present (idempotent).
    if ! "$src/.venv/bin/python" "$src/docker/scripts/download_model.py" --output "$src/api/src/models/v1_0"; then
        die "Failed to download Kokoro model weights"
    fi

    # Japanese TTS needs the UniDic dictionary (~526MB) for fugashi/MeCab.
    # `python -m unidic download` always wipes and re-downloads the ~526MB
    # dict, so only fetch it when it is actually missing from the venv.
    local unidic_dir
    unidic_dir="$("$src/.venv/bin/python" -c "import os, unidic; print(os.path.dirname(os.path.abspath(unidic.__file__)))" 2>/dev/null || true)"
    if [[ -n "$unidic_dir" && -d "$unidic_dir/dicdir" && -f "$unidic_dir/dicdir/lex.csv" ]]; then
        ok "UniDic dictionary already present, skipping download."
    elif confirm "Download the Japanese dictionary (UniDic, ~526MB) for Japanese TTS support?" y; then
        info "Downloading UniDic dictionary for Japanese support..."
        "$src/.venv/bin/python" -m unidic download || warn "UniDic download failed; Japanese TTS will be unavailable."
    fi

    # Create launcher in bin
    make_kokoro_launcher "$src"

    record_version kokoro "$src"
    ok "Installed Kokoro-FastAPI (device: $device)"
}

make_kokoro_launcher() {
    local src="$1"
    local device="${KOKORO_DEVICE:-auto}"
    local espeak_data use_gpu dev
    espeak_data=""
    for d in /usr/share/espeak-ng-data /usr/lib/*/espeak-ng-data; do
        [[ -d "$d" ]] && { espeak_data="$d"; break; }
    done
    case "$device" in
        gpu|gpu-cu128)  use_gpu=true  dev=gpu ;;
        rocm)           use_gpu=true  dev=rocm ;;
        *)              use_gpu=false dev=cpu ;;
    esac
    # Launcher runs uvicorn from the project venv (matching docker/scripts/
    # entrypoint.sh) rather than `uv run`, so it needs no uv on PATH.
    as_root tee "$BIN_DIR/kokoro-fastapi" >/dev/null <<EOF
#!/usr/bin/env bash
# Launcher for Kokoro-FastAPI
SRC="$src"
export PYTHONPATH="\$SRC:\$SRC/api"
export USE_GPU="$use_gpu"
export DEVICE="$dev"
export MODEL_DIR=src/models
export VOICES_DIR=src/voices/v1_0
export WEB_PLAYER_PATH="\$SRC/web"
export PHONEMIZER_ESPEAK_PATH=/usr/bin
export PHONEMIZER_ESPEAK_DATA="$espeak_data"
export ESPEAK_DATA_PATH="$espeak_data"
exec "\$SRC/.venv/bin/python" -m uvicorn api.src.main:app --host "\${KOKORO_HOST:-0.0.0.0}" --port "\${KOKORO_PORT:-8880}"
EOF
    as_root chmod +x "$BIN_DIR/kokoro-fastapi"
}

################################################################################
# llama-swap (Go binary, from release)
################################################################################

install_llama_swap() {
    # llama-swap is a Go project. It is downloaded as a prebuilt release (not
    # compiled from source here - building Go from source is optional if Go is
    # present). Prefer the prebuilt release for reliability.
    local json version installed url archive
    info "Checking llama-swap..."

    json=$(github_release_json mostlygeek/llama-swap 'linux_amd64\.tar\.gz$' 2>/dev/null) || {
        warn "Could not resolve llama-swap release; trying to build from source."
        if command -v go >/dev/null 2>&1; then
            return
        fi
        die "No llama-swap release found and Go not installed."
    }

    version=$(echo "$json" | github_tag)
    installed=$(get_installed_version LLAMA_SWAP)
    if [[ "$version" == "$installed" ]]; then
        ok "llama-swap already current ($version)"
        install_llama_swap_service
        return
    fi

    url=$(echo "$json" | github_asset 'linux_amd64\.tar\.gz$')
    archive="$TMPDIR/llama-swap.tar.gz"
    download "$url" "$archive"

    local dest="$PREFIX/llama-swap"
    as_root rm -rf "$dest"; as_root mkdir -p "$dest"
    as_root tar -xzf "$archive" -C "$dest"
    make_link "$dest/llama-swap" llama-swap

    set_installed_version LLAMA_SWAP "$version"
    install_llama_swap_service
    ok "Installed llama-swap $version"
}

build_llama_swap_from_source() {
    ensure_source_repo llama-swap "$(repo_url llama-swap)" || true
    local go_dir="$LLAMA_SWAP_DIR"
    [[ -d "$go_dir" ]] || die "llama-swap source not found: $go_dir"
    info "Building llama-swap from source..."
    ( cd "$go_dir" && CGO_ENABLED=0 go build -trimpath -o "$TMPDIR/llama-swap" . )
    as_root install -m755 "$TMPDIR/llama-swap" "$BIN_DIR/llama-swap"
    record_version llama-swap "$go_dir"
    install_llama_swap_service
    ok "Built llama-swap from source"
}

################################################################################
# GitHub helpers
################################################################################

github_release_json() {
    local repo="$1" asset_regex="$2" json release
    json=$(curl -fsSL "https://api.github.com/repos/$repo/releases?per_page=30" 2>/dev/null) || return 1
    release=$(echo "$json" | jq -c --arg regex "$asset_regex" '.[] | select(any(.assets[]; .name | test($regex)))' | head -n1)
    [[ -z "$release" ]] && return 1
    printf '%s\n' "$release"
}

github_tag() { jq -r '.tag_name'; }

github_asset() {
    local regex="$1" url
    url=$(jq -r --arg regex "$regex" '.assets[] | select(.name | test($regex)) | .browser_download_url' | head -n1)
    [[ -z "$url" || "$url" == "null" ]] && die "No release asset matched: $regex"
    printf '%s\n' "$url"
}

download() {
    local url="$1" outfile="$2"
    info "Downloading $(basename "$url")"
    curl -fL --progress-bar -o "$outfile" "$url"
}

make_link() {
    as_root ln -sfn "$1" "$BIN_DIR/$2"
}

################################################################################
# systemd service
################################################################################

ensure_llama_swap_user() {
    if ! id -u llama-swap >/dev/null 2>&1; then
        info "Creating system user 'llama-swap'..."
        as_root useradd \
            --system \
            --home-dir "$DATA_DIR" \
            --shell /usr/sbin/nologin \
            llama-swap
    fi
    as_root mkdir -p "$CONFIG_DIR" "$MODEL_DIR"
    as_root chown -R llama-swap:llama-swap "$DATA_DIR"
}

# Install the default llama-swap config ($CONFIG_DIR/config.yaml) from the
# repository's config/config.yaml when none exists yet, then append the
# kokoro-tts model entry when Kokoro is installed. ${PORT} is expanded by
# llama-swap at runtime, so it must be written literally into the YAML; every
# heredoc in here is therefore quoted to stop the shell from touching it.
install_llama_swap_config() {
    as_root mkdir -p "$CONFIG_DIR"
    local cfg="$CONFIG_DIR/config.yaml"
    if [[ ! -s "$cfg" ]]; then
        local src
        src="$(dirname "$0")/config/config.yaml"
        if [[ -f "$src" ]]; then
            info "Installing default llama-swap config from $src"
            as_root install -m0644 "$src" "$cfg"
        else
            warn "config/config.yaml not found next to the installer; writing embedded default."
            as_root tee "$cfg" >/dev/null <<'CFG'
models:
  gemma-4-E2B:
    filters:
      stripParams: "temperature, top_k, top_p, repeat_penalty, min_p, presence_penalty"
    capabilities:
      in: [text, image, audio]
      out: [text]
      tools: true
      context: 131072
    cmd: |
      llama-server
      --host 127.0.0.1 --port ${PORT}
      --temp 1.0 --top-p 0.95 --top-k 64
      -hf unsloth/gemma-4-E2B-it-GGUF:Q4_K_M
      --spec-type draft-mtp
      --spec-draft-n-max 4 --spec-draft-p-min 0.75
CFG
        fi
        as_root chown llama-swap:llama-swap "$cfg"
        ok "Default llama-swap config installed."
    fi

    # Only add kokoro-tts when Kokoro is actually installed.
    if [[ -f "$BIN_DIR/kokoro-fastapi" ]] && ! grep -qs '^  kokoro-tts:' "$cfg"; then
        info "Adding kokoro-tts model to llama-swap config."
        # Never glue the entry onto an existing line: ensure a trailing newline.
        if [[ -s "$cfg" ]] && [[ "$(tail -c1 "$cfg")" != "$(printf '\n')" ]]; then
            as_root tee -a "$cfg" >/dev/null <<'NL'
NL
        fi
        as_root tee -a "$cfg" >/dev/null <<'KOKOROCFG'
  kokoro-tts:
    useModelName: "tts-1"
    capabilities:
      in: [text]
      out: [audio]
    cmd: |
      /bin/bash -c 'export KOKORO_HOST=127.0.0.1; export KOKORO_PORT=${PORT}; exec /opt/ai-stack/bin/kokoro-fastapi'
    proxy: http://127.0.0.1:${PORT}
KOKOROCFG
        as_root chown llama-swap:llama-swap "$cfg"
        ok "kokoro-tts added to llama-swap config."
    fi
}

# Grant the llama-swap service user traverse access to the real user's home so
# it can reach Kokoro's venv python. Only /home/<user> is touched, and only
# when Kokoro is installed. Never chmod 777 or chown the home directory.
fix_kokoro_permissions() {
    [[ -f "$BIN_DIR/kokoro-fastapi" ]] || return 0
    local venv_py="$SOURCE_DIR/Kokoro-FastAPI/.venv/bin/python"
    if [[ ! -x "$venv_py" ]]; then
        warn "Kokoro launcher present but venv python not found ($venv_py); skipping ACL."
        return 0
    fi
    if ! command -v setfacl >/dev/null 2>&1; then
        warn "setfacl not available; skipping Kokoro permission fix."
        return 0
    fi
    as_root setfacl -m u:llama-swap:x "$HOME"
    ok "Granted llama-swap traverse access to $HOME (ACL)."
}

install_llama_swap_service() {
    info "Installing llama-swap systemd service..."
    ensure_llama_swap_user
    install_llama_swap_config
    fix_kokoro_permissions
    local SERVICE=/etc/systemd/system/llama-swap.service
    # Write the unit unless it already points at our bin dir; a leftover unit
    # from the old /opt/ai prefix is rewritten to the current one.
    if [[ ! -f "$SERVICE" ]] || ! grep -qs "$BIN_DIR/llama-swap" "$SERVICE"; then
        as_root tee "$SERVICE" >/dev/null <<EOF
[Unit]
Description=llama-swap AI Model Router
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=llama-swap
Group=llama-swap

Environment="PATH=$BIN_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
Environment="LLAMA_CACHE=$MODEL_DIR"

ExecStart=$BIN_DIR/llama-swap \
    -config $CONFIG_DIR/config.yaml \
    -listen 0.0.0.0:9999 \
    -watch-config

Restart=always
RestartSec=5

WorkingDirectory=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF
        as_root systemctl daemon-reload
        ok "Installed systemd service."
    else
        ok "Systemd service already exists."
    fi
    # Enabled at boot; restart if it is running, otherwise start it now.
    as_root systemctl enable llama-swap.service 2>/dev/null || true
    if systemctl is-active --quiet llama-swap.service 2>/dev/null; then
        info "llama-swap is running; restarting to pick up changes."
        as_root systemctl restart llama-swap.service 2>/dev/null || true
    else
        info "llama-swap is not running; starting it now."
        as_root systemctl start llama-swap.service 2>/dev/null || true
    fi
}

################################################################################
# Uninstall
################################################################################

uninstall() {
    require_sudo
    info "Removing installed software..."
    if systemctl list-unit-files 2>/dev/null | grep -q '^llama-swap.service'; then
        as_root systemctl stop llama-swap.service 2>/dev/null || true
        as_root systemctl disable llama-swap.service 2>/dev/null || true
        as_root rm -f /etc/systemd/system/llama-swap.service
        as_root systemctl daemon-reload
    fi
    as_root rm -f /etc/ld.so.conf.d/ai-stack.conf /etc/ld.so.conf.d/ai-whisper.conf
    as_root ldconfig 2>/dev/null || true
    as_root rm -rf "$PREFIX"
    ok "Removed installed software."
    if [[ "${PURGE_DATA:-0}" == 1 ]]; then
        as_root rm -rf "$DATA_DIR"
        ok "Removed data directory."
    else
        echo
        echo "User data was preserved:"
        echo "  $DATA_DIR"
        echo "Delete it manually or rerun with --purge-data."
    fi
    echo
    note "Source and build trees were kept (user-owned):"
    note "  $SOURCE_DIR"
    note "  $BUILD_DIR"
}

################################################################################
# Summary
################################################################################

summary() {
    echo
    echo "===================================================="
    echo "Installation complete"
    echo
    echo "Installed to: $PREFIX"
    echo "llama-swap data: $DATA_DIR"
    echo "     stack config: $STACK_CONF"
    echo
    echo "Versions:"
    for c in llama ik-llama sd whisper kokoro crispasr acestep audio; do
        local key ver backend
        key="$(tr 'a-z-' 'A-Z_' <<< "$c" | sed 's/-/_/g')"
        ver="$(get_installed_version "$key")"
        local varname backendv
        varname="$(backend_varname "$c")"
        backendv="${!varname:-auto}"
        echo "  $c: ${ver:-?} (backend: ${backendv:-auto})"
    done
    echo "  llama-swap: $(get_installed_version LLAMA_SWAP)"
    echo
    echo "Executables in $BIN_DIR:"
    for c in llama ik-llama sd whisper acestep audio crispasr; do
        IFS=' ' read -r -a links <<< "$(component_links "$c")"
        local k=1
        while [[ $k -lt ${#links[@]} ]]; do
            echo "  $BIN_DIR/${links[$k]}"
            k=$((k+2))
        done
    done
    [[ -f "$BIN_DIR/kokoro-fastapi" ]] && echo "  $BIN_DIR/kokoro-fastapi"
    [[ -f "$BIN_DIR/llama-swap" ]] && echo "  $BIN_DIR/llama-swap"
    echo
    echo "Add this to your ~/.bashrc if needed:"
    echo "export PATH=$BIN_DIR:\$PATH"
    echo
    echo "===================================================="
}

################################################################################
# Memory, swap, and build jobs
################################################################################

# Parallel build jobs: scaled off total RAM+swap (tights thresholds), honoring
# --jobs, always capped at nproc.
build_jobs() {
    local nproc_avail jobs ram_kb swap_kb combined_gb
    nproc_avail="$(nproc 2>/dev/null || echo 1)"
    if [[ -n "${BUILD_JOBS_ARG:-}" ]]; then
        jobs="$BUILD_JOBS_ARG"
    else
        read -r ram_kb swap_kb <<< "$(system_memory)"
        combined_gb=$(( (ram_kb + swap_kb) / 1024 / 1024 ))
        if (( combined_gb < 4 )); then
            jobs=1
        elif (( combined_gb < 6 )); then
            jobs=2
        elif (( combined_gb < 8 )); then
            jobs=3
        elif (( combined_gb < 12 )); then
            jobs=4
        elif (( combined_gb < 16 )); then
            jobs=6
        else
            jobs="$nproc_avail"
        fi
    fi
    (( jobs > nproc_avail )) && jobs="$nproc_avail"
    (( jobs < 1 )) && jobs=1
    echo "$jobs"
}

# Prints "ram_kb swap_kb" from /proc/meminfo and /proc/swaps.
system_memory() {
    local ram_kb swap_kb
    ram_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    swap_kb="$(awk 'NR>1 {s+=$3} END {print s+0}' /proc/swaps 2>/dev/null || echo 0)"
    echo "$ram_kb $swap_kb"
}

check_memory() {
    local ram_kb swap_kb combined_gb _have_audio=0 c
    read -r ram_kb swap_kb <<< "$(system_memory)"
    combined_gb=$(( (ram_kb + swap_kb) / 1024 / 1024 ))
    if (( combined_gb >= 16 )); then
        ok "Memory check passed: ${combined_gb} GiB RAM+swap detected."
        return
    fi
    for c in "${INSTALL_LIST[@]:-}"; do
        [[ "$c" == "audio" ]] && { _have_audio=1; break; }
    done
    echo
    note "Low memory detected:"
    note "  RAM:      $(( ram_kb / 1024 / 1024 )) GiB"
    note "  Swap:     $(( swap_kb / 1024 / 1024 )) GiB"
    note "  Combined: ${combined_gb} GiB"
    note "16 GiB combined RAM+swap is recommended."
    echo
    # Extra swap is really only worth it for the heavy audio.cpp build.
    if (( _have_audio != 1 )); then
        warn "Continuing with ${combined_gb} GiB RAM+swap (audio.cpp not selected; other builds fit)."
        return
    fi
    if [[ "$AUTO_YES" == 1 || "$NO_SWAP" == 1 ]]; then
        warn "Continuing with ${combined_gb} GiB RAM+swap (the audio.cpp build may be slow or fail)."
        return
    fi
    local choice
    choice="$(menu_choice "audio.cpp is a heavy build. What would you like to do?" \
        "Continue (audio.cpp build may be slow or fail)" \
        "Create swapfile (${SWAP_SIZE})" \
        "Abort")"
    case "$choice" in
        Continue*) warn "Continuing with ${combined_gb} GiB RAM+swap." ;;
        Create*)   create_swapfile ;;
        Abort*)    die "Aborting." ;;
        *)         die "Unknown choice." ;;
    esac
}

# Converts sizes like "8G" / "512M" / "1024K" to kibibytes; bare numbers = GiB.
size_to_kb() {
    local size="$1"
    case "$size" in
        *G) echo $(( ${size%G} * 1024 * 1024 )) ;;
        *M) echo $(( ${size%M} * 1024 )) ;;
        *K) echo ${size%K} ;;
        *)  echo $(( size * 1024 * 1024 )) ;;
    esac
}

# Size of an existing swapfile in kibibytes (from the file itself).
swap_file_kb() {
    stat -c%s "$1" 2>/dev/null | awk '{print int($1/1024)}'
}

swap_dd() {
    local size="$1" file="$2" blocks
    case "$size" in
        *G) blocks=$(( ${size%G} * 1024 )) ;;
        *M) blocks=${size%M} ;;
        *)  blocks=$(( size * 1024 )) ;;
    esac
    as_root dd if=/dev/zero of="$file" bs=1M count="$blocks" status=progress
}

# Carve out the swapfile with fallocate (dd as fallback).
allocate_swapfile() {
    local file="$1" size="$2"
    if command -v fallocate >/dev/null 2>&1 && as_root fallocate -l "$size" "$file"; then
        return
    fi
    warn "fallocate failed; using dd."
    swap_dd "$size" "$file"
}

# Initialize and enable an (already carved-out) swapfile. persistent=1 adds an
# /etc/fstab entry so it survives reboots.
activate_swapfile() {
    local file="$1" persistent="$2"
    as_root chmod 600 "$file"
    as_root mkswap "$file"
    as_root swapon "$file"
    if [[ "$persistent" == "1" ]] && ! grep -qF "$file" /etc/fstab 2>/dev/null; then
        info "Persisting swap entry in /etc/fstab..."
        echo "$file none swap sw 0 0" | as_root tee -a /etc/fstab >/dev/null
    fi
}

# Resize an existing active swapfile: swapoff, recreate, re-enable (persistent).
resize_swapfile() {
    local file="$1" size="$2"
    note "Temporarily disabling $file (swapoff)..."
    if ! as_root swapoff "$file"; then
        warn "swapoff $file failed; cannot resize in place. Falling back to a temporary swapfile."
        create_temporary_swapfile "$size"
        return 1
    fi
    as_root rm -f "$file"
    allocate_swapfile "$file" "$size"
    activate_swapfile "$file" 1
    ok "Resized $file to $size and re-enabled it."
}

# Add a swapfile that exists only for this run and is removed afterwards;
# it is never persisted to /etc/fstab.
create_temporary_swapfile() {
    local size="$1"
    local file=/swapfile.ai-stack-tmp
    if swapon --show --noheadings 2>/dev/null | grep -qF "$file"; then
        note "Temporary swapfile $file is already active."
    else
        info "Creating temporary swapfile $file of size $size (removed after this run)..."
        allocate_swapfile "$file" "$size"
        activate_swapfile "$file" 0
    fi
    TEMP_SWAPFILE="$file"
    ok "Temporary swapfile $file is active (${size})."
}

# Remove and delete the temporary swapfile, if one was created this run.
cleanup_temporary_swap() {
    [[ -n "${TEMP_SWAPFILE:-}" ]] || return
    if swapon --show --noheadings 2>/dev/null | grep -qF "$TEMP_SWAPFILE"; then
        note "Removing temporary swapfile $TEMP_SWAPFILE..."
        as_root swapoff "$TEMP_SWAPFILE" 2>/dev/null || true
    fi
    as_root rm -f "$TEMP_SWAPFILE" 2>/dev/null || true
    TEMP_SWAPFILE=""
}

create_swapfile() {
    local size="$SWAP_SIZE"
    local swapfile=/swapfile
    local want_kb current_kb

    want_kb="$(size_to_kb "$size")"

    # Existing *active* swapfile at the default location
    if [[ -f "$swapfile" ]] && swapon --show --noheadings 2>/dev/null | grep -qF "$swapfile"; then
        current_kb="$(swap_file_kb "$swapfile")"
        if (( current_kb >= want_kb )); then
            ok "Existing $swapfile is already $(( current_kb / 1024 / 1024 )) GiB (>= $size); no change needed."
            return
        fi
        echo
        note "Your existing $swapfile is $(( current_kb / 1024 / 1024 )) GiB (recommended: $size)."
        local choice
        choice="$(menu_choice "How should I handle swap?" \
            "Resize $swapfile to ${size} (temporarily disables swap)" \
            "Add a separate temporary swapfile (${size}, removed after this run)" \
            "Skip (continue without extra swap)")"
        case "$choice" in
            Resize*) resize_swapfile "$swapfile" "$size" ;;
            Add*)    create_temporary_swapfile "$size" ;;
            Skip*)   warn "Continuing without extra swap." ;;
            *)       warn "Unknown choice; continuing without extra swap." ;;
        esac
        return
    fi

    # No active root swapfile: create (or reuse + resize) a persistent one.
    if [[ ! -f "$swapfile" ]]; then
        info "Creating swapfile $swapfile of size $size..."
    else
        note "Reusing existing inactive $swapfile (resizing to $size)..."
    fi
    allocate_swapfile "$swapfile" "$size"
    activate_swapfile "$swapfile" 1
    ok "Swapfile $swapfile is active (${size})."
}

# Main
################################################################################

main() {
    require_sudo

    as_root mkdir -p "$PREFIX" "$BIN_DIR"
    as_root touch "$VERSIONS_FILE"
    mkdir -p "$SOURCE_DIR" "$BUILD_DIR"

    # remember CLI-provided overrides so load_config does not clobber them
    local cli_kokoro="${KOKORO_DEVICE:-}"
    local cli_archs="${CUDA_ARCHS:-native}"
    load_config
    [[ -n "$cli_kokoro" ]] && KOKORO_DEVICE="$cli_kokoro"
    [[ -n "${CUDA_ARCHS_ARG:-}" ]] && CUDA_ARCHS="$cli_archs"

    # Ask everything first; only touch apt / install toolchains afterwards,
    # based on what was actually chosen.
    install_components
    select_backends "${INSTALL_LIST[@]}"

    # Persist choices now so a failed build doesn't discard them; main()
    # re-saves after builds pick up any resolved KOKORO_DEVICE.
    save_config

    # Preflight now that components are known: warn on low RAM+swap, and only
    # offer extra swap when the heavy audio.cpp build is selected. Also pick
    # the parallel build job count (RAM+swap-scaled, capped at nproc).
    check_memory
    BUILD_JOBS="$(build_jobs)"
    note "Build jobs: $BUILD_JOBS (RAM+swap-scaled, capped at nproc)"
    echo

    ensure_source_repos
    ensure_runtime_dependencies
    ensure_backend_dependencies
    ensure_build_dependencies
    ensure_nodejs

    info "Starting builds..."
    echo

    local built_any=0
    for c in "${INSTALL_LIST[@]}"; do
        if is_up_to_date "$c"; then
            local ckey
            ckey="$(tr 'a-z-' 'A-Z_' <<< "$c" | sed 's/-/_/g')"
            ok "$c is already up to date at $(get_installed_version "$ckey")"
            continue
        fi
        case "$c" in
            llama|ik-llama|sd|whisper|acestep|audio|crispasr)
                build_and_install "$c"; built_any=1 ;;
            kokoro)
                install_kokoro; built_any=1 ;;
            *) warn "Unknown component: $c; skipping" ;;
        esac
    done

    # llama-swap is always installed
    if command -v go >/dev/null 2>&1 && [[ ! -f "$BIN_DIR/llama-swap" ]]; then
        build_llama_swap_from_source
    else
        install_llama_swap
    fi

    save_config

    cleanup_build_dependencies
    cleanup_temporary_swap

    summary
}

if [[ "${UNINSTALL:-0}" == 1 ]]; then
    uninstall
    exit 0
fi

main
