#!/usr/bin/env bash
# Install, update, download, or start the foreground server.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$ROOT/.tools/bin:$PATH"

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  printf 'Usage: bash setup.sh [--update]\n\nChoose 1 to build fngine and download the heretic Qwen3.8-Flash-Next pack.\nChoose 2 to download or resume the model download.\nChoose 3 to start the server with the manifest profile.\nChoose 4, or run bash setup.sh --update, to update this installer, rebuild the\nruntime at its new pin, and replace model files that no longer match the new pin\n(they are moved to models/Qwen3.8-Flash-Next-heretic-fngine.previous-<time>/,\nnot deleted). Serving requires Linux x86_64, an RTX 5090 with working NVIDIA\ndrivers, an AVX-512 CPU (Zen 4/5 or Sapphire Rapids and later) and ~60 GB RAM.\nAllow about 86.8 GB for model files, plus software and download working space.\n'
  exit 0
fi
# --update-continue is internal: after --update (or option 4) pulls the installer, the pulled
# setup.sh finishes the update, then shows the menu if --menu follows. Keep accepting it, so
# older copies can hand an update over to newer ones.
update=""
show_menu=1
case "$*" in
  "") ;;
  --update) update=pull; show_menu=0 ;;
  --update-continue) update="continue"; show_menu=0 ;;
  "--update-continue --menu") update="continue" ;;
  *)
    echo "Unexpected arguments; use bash setup.sh --help for usage." >&2
    exit 2
    ;;
esac
if [[ ! -t 0 ]]; then
  echo "Run bash setup.sh in an interactive terminal (or use --help)." >&2
  exit 2
fi
active_step=""
interrupt_setup() {
  trap '' INT
  if [[ -n "$active_step" ]]; then
    kill -TERM -- "-$active_step" 2>/dev/null || true
    wait "$active_step" 2>/dev/null || true
  fi
  if [[ -n "$update" ]]; then
    printf '\nInterrupted. Run the update again to continue it.\n'
  else
    printf '\nInterrupted. Choose 1 to continue installation or 2 to resume the download.\n'
  fi
  exit 130
}
trap interrupt_setup INT

run_step() {
  # Keep Bash's interrupt trap responsive and stop all download/build workers.
  setsid "$@" &
  active_step=$!
  local status=0
  wait "$active_step" || status=$?
  active_step=""
  return "$status"
}

check_hardware() {
  if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    echo "This recipe requires Linux x86_64; Apple, AMD GPU and CPU-only inference are not supported." >&2
    return 1
  fi
  if ! command -v nvidia-smi >/dev/null; then
    echo "Install your NVIDIA driver first. This menu does not install or change drivers." >&2
    return 1
  fi
  local gpus flags flag missing_flags=() ram_gib
  if ! gpus="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader)"; then
    echo "The NVIDIA driver is not working. Fix it before continuing." >&2
    return 1
  fi
  printf '\nDetected GPU(s):\n%s\n' "$gpus"
  if [[ "$gpus" != *"RTX 5090"* ]]; then
    echo "Warning: this preset targets RTX 5090 32 GB (Blackwell sm_120a); other GPUs are untested."
  fi
  flags=" $(grep -m1 '^flags' /proc/cpuinfo | cut -d: -f2) "
  for flag in avx512f avx512bw avx512dq avx512vl avx512_vnni avx512_bf16 avx512vbmi avx512_bitalg avx512_vpopcntdq; do
    [[ "$flags" == *" $flag "* ]] || missing_flags+=("$flag")
  done
  if [[ ${#missing_flags[@]} != 0 ]]; then
    echo "This CPU lacks ${missing_flags[*]}. fngine runs part of the model on the CPU and needs AVX-512 with VNNI, BF16, VBMI, BITALG and VPOPCNTDQ (AMD Zen 4/5, Intel Sapphire Rapids or later)." >&2
    return 1
  fi
  ram_gib=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1048576 ))
  if (( ram_gib < 60 )); then
    echo "Warning: ${ram_gib} GiB of RAM detected; the CPU expert tier, embedding and n-gram cache need about 60 GB."
  fi
}

# A GCC that CUDA 13.3 accepts as its host compiler (12 to 15); scripts/install.sh asks nvcc
# itself. An explicit CUDAHOSTCXX (for example a clang++) is left to that check.
has_cuda_host_compiler() {
  local candidate major
  if [[ -n "${CUDAHOSTCXX:-}" ]] && command -v "$CUDAHOSTCXX" >/dev/null; then
    return 0
  fi
  for candidate in c++ g++-15 g++-14 g++-13 g++-12; do
    command -v "$candidate" >/dev/null || continue
    [[ "$("$candidate" --version 2>/dev/null | head -1)" != *clang* ]] || continue
    major="$("$candidate" -dumpversion 2>/dev/null | cut -d. -f1)"
    if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 12 && major <= 15 )); then
      return 0
    fi
  done
  return 1
}

check_system_tools() {
  local command missing=0
  for command in curl git cc c++ pkg-config setsid; do
    if ! command -v "$command" >/dev/null; then
      printf 'Missing system tool: %s\n' "$command" >&2
      missing=1
    fi
  done
  if command -v pkg-config >/dev/null && ! pkg-config --exists liburing; then
    echo "Missing liburing development files." >&2
    missing=1
  fi
  if command -v c++ >/dev/null && ! has_cuda_host_compiler; then
    echo "Missing a host compiler for CUDA 13.3 (GCC 12 to 15); the system compiler is newer." >&2
    missing=1
  fi
  return "$missing"
}

ensure_system_tools() {
  if check_system_tools; then
    return 0
  fi
  local answer
  local package_command=() privilege=()
  if command -v apt-get >/dev/null; then
    package_command=(apt-get install -y build-essential git curl pkg-config util-linux liburing-dev)
  elif command -v dnf >/dev/null; then
    package_command=(dnf install -y gcc gcc-c++ make git curl pkgconf-pkg-config util-linux liburing-devel)
  elif command -v pacman >/dev/null; then
    package_command=(pacman -S --needed base-devel git curl pkgconf util-linux liburing)
    if command -v c++ >/dev/null && ! has_cuda_host_compiler; then
      package_command+=(gcc15)
    fi
  else
    echo "Install the missing build tools and development libraries, then choose 1 again." >&2
    return 1
  fi
  if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null; then
      echo "Ask your administrator to install the missing tools, then choose 1 again." >&2
      return 1
    fi
    privilege=(sudo)
  fi
  printf '\nSystem package command: %s\n' "${privilege[*]} ${package_command[*]}"
  echo "On apt-based systems, package lists will also be refreshed first."
  if ! read -r -p "Install these system build tools? [y/N] " answer; then
    return 1
  fi
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "No system packages changed."; return 1 ;;
  esac
  if [[ "${package_command[0]}" == apt-get ]]; then
    "${privilege[@]}" apt-get update || return 1
  fi
  "${privilege[@]}" "${package_command[@]}" || return 1
  if ! check_system_tools; then
    echo "If only the CUDA host compiler is missing, install GCC 12-15 (for example g++-14) or set CUDAHOSTCXX." >&2
    return 1
  fi
}

ensure_uv() {
  if command -v uv >/dev/null; then
    return 0
  fi
  local installer status
  echo "Installing uv from https://astral.sh/uv/install.sh into .tools/bin (no shell profile changes)."
  installer="$(mktemp)" || return 1
  if ! curl --fail --show-error --location --proto '=https' --tlsv1.2 \
    https://astral.sh/uv/install.sh --output "$installer"; then
    rm -f -- "$installer"
    return 1
  fi
  status=0
  UV_UNMANAGED_INSTALL="$ROOT/.tools/bin" sh "$installer" || status=$?
  rm -f -- "$installer"
  if [[ $status -ne 0 ]]; then
    return "$status"
  fi
  command -v uv >/dev/null
}

download_models() {
  local command
  for command in curl setsid; do
    if ! command -v "$command" >/dev/null; then
      printf 'Missing %s. Install it, or choose 1 for system prerequisite setup.\n' "$command" >&2
      return 1
    fi
  done
  ensure_uv || return 1
  run_step bash "$ROOT/scripts/install.sh" --download-only || return 1
  run_step "$ROOT/.venv/bin/python" "$ROOT/scripts/download_models.py"
}

build_and_download() {
  # Arguments go to download_models.py.
  check_hardware || return 1
  ensure_system_tools || return 1
  ensure_uv || return 1
  printf '\n[1/2] Installing local tools and building the pinned fngine runtime...\n'
  run_step bash "$ROOT/scripts/install.sh" || return 1
  printf '\n[2/2] Downloading and verifying the heretic pack and its licenses...\n'
  run_step "$ROOT/.venv/bin/python" "$ROOT/scripts/download_models.py" "$@"
}

install_everything() {
  build_and_download || return 1
  printf '\nInstallation complete. Choose 3 to start the server.\n'
}

# Fast-forwards this clone to the published installer, whose manifest pins the current runtime
# and model. Local edits that the update does not touch are kept.
update_installer() {
  local top before after
  if ! command -v git >/dev/null; then
    echo "Missing git. Install it, then run the update again." >&2
    return 1
  fi
  top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [[ -z "$top" || ! "$top" -ef "$ROOT" ]]; then
    echo "This folder is not a git clone of the installer, so it cannot update itself." >&2
    echo "Clone https://github.com/satellitedown/flash-next-abliterated-fngine and install from it." >&2
    return 1
  fi
  before="$(git -C "$ROOT" rev-parse HEAD)" || return 1
  printf '\nFetching the latest installer...\n'
  git -C "$ROOT" fetch --quiet origin main || return 1
  if ! git -C "$ROOT" merge --quiet --ff-only FETCH_HEAD; then
    echo "Local commits or edits in this folder conflict with the update; nothing was changed." >&2
    echo "Review them with git status, save or undo them, then run the update again." >&2
    return 1
  fi
  after="$(git -C "$ROOT" rev-parse HEAD)" || return 1
  if [[ "$after" == "$before" ]]; then
    echo "The installer is already up to date."
  else
    printf 'Installer updated from %s to %s:\n' "${before:0:7}" "${after:0:7}"
    git -C "$ROOT" log -n 10 --format='  %s' "$before..$after" || true
  fi
}

# Builds the runtime this installer pins and moves model files that do not match its pin aside.
finish_update() {
  build_and_download --set-aside-mismatched || return 1
  if [[ "$show_menu" == 1 ]]; then
    printf '\nUpdate complete. Choose 3 to start the server; restart one that is already running.\n'
  else
    printf '\nUpdate complete. Start the server with bash setup.sh, option 3; restart one that is already running.\n'
  fi
}

if [[ "$update" == pull ]]; then
  if ! update_installer; then
    printf '\nUpdate did not finish. Fix the error above, then run it again.\n' >&2
    exit 1
  fi
  exec bash "$ROOT/setup.sh" --update-continue
fi
if [[ "$update" == continue ]]; then
  if ! finish_update; then
    printf '\nUpdate did not finish. Fix the error above, then run it again.\n' >&2
    [[ "$show_menu" == 1 ]] || exit 1
  fi
  [[ "$show_menu" == 1 ]] || exit 0
  update=""
fi

while true; do
  printf '\nQwen3.8-Flash-Next heretic - fngine\n'
  printf 'RTX 5090 + AVX-512 CPU expert tier, 256K context, MTP speculation\n\n'
  printf '  1) Install everything (build + download)\n'
  printf '  2) Download / resume model\n'
  printf '  3) Start the server (Ctrl-C to stop)\n'
  printf '  4) Update to the latest version\n'
  printf '  0) Exit\n\n'
  printf 'Space: ~86.8 GB model files, plus software and download working space.\n'
  if ! read -r -p "Choose an option: " choice; then
    printf '\n'
    exit 0
  fi
  case "$choice" in
    1)
      if ! install_everything; then
        printf '\nSetup did not finish. Fix the error above, then choose 1 again.\n' >&2
      fi
      ;;
    2)
      if ! download_models; then
        printf '\nDownload did not finish. Fix the error above, then retry.\n' >&2
      fi
      ;;
    3)
      if [[ ! -x "$ROOT/runtime/fngine/build/apps/fngine-serve" ]]; then
        echo "Choose 1 to build the runtime and download the model first." >&2
      elif check_hardware; then
        exec bash "$ROOT/scripts/serve.sh"
      fi
      ;;
    4)
      update=pull
      if update_installer; then
        exec bash "$ROOT/setup.sh" --update-continue --menu
      fi
      update=""
      printf '\nUpdate did not finish. Fix the error above, then choose 4 again.\n' >&2
      ;;
    0|q|Q) exit 0 ;;
    *) echo "Choose 1, 2, 3, 4, or 0." ;;
  esac
done
