#!/usr/bin/env bash
# Install pinned Python tools and runtime source, optionally building the server.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat <<'HELP'
Usage: bash scripts/install.sh [--download-only]

Install the locked Python 3.12 tools and the pinned fngine source, then install the
isolated CUDA SDK and build runtime/fngine/build/apps/fngine-serve. --download-only
installs just the Python tools for menu option 2, without runtime source, CUDA, or
compilation.

Run bash setup.sh to install missing system build prerequisites with permission.
A CUDA-compatible NVIDIA driver is required to build and serve, not to download.
CC and CXX select the C and C++20 compilers (default cc and c++). CUDAHOSTCXX selects
the compiler nvcc uses for host code; by default the first of $CXX, g++-15, g++-14,
g++-13 and g++-12 that the pinned nvcc accepts.
HELP
  exit 0
fi

DOWNLOAD_ONLY=0
if [[ $# == 1 && "$1" == --download-only ]]; then
  DOWNLOAD_ONLY=1
elif [[ $# != 0 ]]; then
  fail 'Unexpected arguments; use --help for usage.'
fi

[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || fail 'This recipe requires Linux x86_64.'

if [[ -x "$ROOT/.tools/bin/uv" ]]; then
  UV="$ROOT/.tools/bin/uv"
elif command -v uv >/dev/null; then
  UV="$(command -v uv)"
else
  fail 'uv is missing. Run bash setup.sh to bootstrap the local tool.'
fi
[[ ! -L "$ROOT/.venv" ]] || fail "Refusing to modify a symlinked installation directory: $ROOT/.venv. Use a repository-local installation."
if [[ ! -x "$ROOT/.venv/bin/python" ]]; then
  [[ ! -e "$ROOT/.venv" ]] || fail 'An incomplete .venv already exists. Move it aside before installing; no files were removed.'
  "$UV" venv --python 3.12 "$ROOT/.venv"
fi
PYTHON="$ROOT/.venv/bin/python"
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 12) else "This recipe requires Python 3.12; move the existing .venv aside and rerun setup.")'
"$UV" pip install --python "$PYTHON" --no-deps -r "$ROOT/requirements.lock"
if [[ "$DOWNLOAD_ONLY" == 1 ]]; then
  printf '\nDownload tools are ready.\n'
  exit 0
fi

# The CPU expert tier is compiled for this CPU and needs these AVX-512 extensions.
cpu_flags=" $(grep -m1 '^flags' /proc/cpuinfo | cut -d: -f2) "
missing_flags=()
for flag in avx512f avx512bw avx512dq avx512vl avx512_vnni avx512_bf16 avx512vbmi avx512_bitalg avx512_vpopcntdq; do
  [[ "$cpu_flags" == *" $flag "* ]] || missing_flags+=("$flag")
done
[[ ${#missing_flags[@]} == 0 ]] || fail "This CPU lacks ${missing_flags[*]}. fngine's CPU expert tier needs AVX-512 with VNNI, BF16, VBMI, BITALG and VPOPCNTDQ (AMD Zen 4/5, Intel Sapphire Rapids or later)."

command -v git >/dev/null || fail 'Missing git. Install it or run bash setup.sh and choose 1.'
for directory in "$ROOT/runtime" "$ROOT/runtime/fngine"; do
  [[ ! -L "$directory" ]] || fail "Refusing to modify a symlinked installation directory: $directory. Use a repository-local installation."
done

runtime_config="$("$PYTHON" - "$ROOT/runtime-manifest.json" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    runtime = json.load(stream)["runtime"]
if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", runtime["repo_id"]):
    sys.exit("Invalid runtime repo_id in runtime-manifest.json")
if not re.fullmatch(r"[0-9a-f]{40}", runtime["revision"]):
    sys.exit("The runtime revision must be a full Git commit in runtime-manifest.json")
if (runtime["cuda_architectures"], runtime["cuda_version"], runtime["build_type"]) != ("120a", "13.3.73", "Release"):
    sys.exit("This recipe requires CUDA 13.3.73, sm_120a and a Release build.")
if not (isinstance(runtime["build_jobs"], int) and 1 <= runtime["build_jobs"] <= 64):
    sys.exit("Invalid build_jobs in runtime-manifest.json")
for key in ("repo_id", "revision", "cuda_architectures", "cuda_version", "build_type", "build_jobs"):
    print(runtime[key])
PY
)"
mapfile -t runtime_values <<< "$runtime_config"
REPO_URL="https://github.com/${runtime_values[0]}.git"
REVISION="${runtime_values[1]}"
SOURCE="$ROOT/runtime/fngine"
BUILD="$SOURCE/build"

# Never reset or clean an existing checkout. A failed fetch can be resumed, while
# local source changes are left untouched rather than silently incorporated.
if [[ ! -e "$SOURCE" ]]; then
  mkdir -p "$ROOT/runtime"
  git init "$SOURCE"
  git -C "$SOURCE" remote add origin "$REPO_URL"
fi
[[ -d "$SOURCE/.git" ]] || fail "Expected an independent Git checkout at $SOURCE. Move the existing directory aside; it was not changed."
[[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=normal)" ]] || fail "Local changes exist in $SOURCE. Save them before rerunning; no reset or cleanup was performed."
if ! git -C "$SOURCE" cat-file -e "$REVISION^{commit}" 2>/dev/null; then
  git -C "$SOURCE" fetch --depth 1 "$REPO_URL" "$REVISION"
fi
if [[ "$(git -C "$SOURCE" rev-parse --verify HEAD 2>/dev/null || true)" != "$REVISION" ]]; then
  git -C "$SOURCE" checkout --detach "$REVISION"
fi

[[ ! -L "$ROOT/.cuda-toolkit" ]] || fail 'Refusing to modify a symlinked .cuda-toolkit directory.'
command -v pkg-config >/dev/null || fail 'Missing pkg-config. Run bash setup.sh and choose 1.'
pkg-config --exists liburing || fail 'Missing liburing development files. Run bash setup.sh and choose 1.'
CC="${CC:-cc}"
CXX="${CXX:-c++}"
CC="$(command -v "$CC")" || fail 'A C compiler is required (CC must name one executable).'
CXX="$(command -v "$CXX")" || fail 'A C++20 compiler is required (CXX must name one executable).'

# Link to the installed driver, never to a toolkit stub. A versioned driver library
# also works on distributions that do not ship an unversioned development symlink.
DRIVER_LIBRARY="$("$CXX" -print-file-name=libcuda.so.1)"
if [[ ! -f "$DRIVER_LIBRARY" ]]; then
  DRIVER_LIBRARY="$("$CXX" -print-file-name=libcuda.so)"
fi
[[ -f "$DRIVER_LIBRARY" ]] || fail 'Cannot find the NVIDIA driver library (libcuda.so.1). Make the installed driver user-space libraries available to your compiler; this recipe does not install drivers.'
"$UV" pip install --python "$PYTHON" --target "$ROOT/.cuda-toolkit" \
  --no-deps -r "$ROOT/requirements-cuda.lock"
export CUDA_HOME="$ROOT/.cuda-toolkit/nvidia/cu13"
export PATH="$ROOT/.venv/bin:$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# NVIDIA's wheels omit the linker/layout aliases required by CMake. Keep existing
# correct aliases, and refuse to overwrite unrelated files or symlinks.
ensure_link() {
  local target="$1" link="$2"
  if [[ -e "$link" || -L "$link" ]]; then
    [[ "$link" -ef "$(dirname -- "$link")/$target" ]] || fail "Unexpected CUDA layout at $link. Move it aside and rerun; it was not overwritten."
  else
    ln -s "$target" "$link"
  fi
}
ensure_link lib "$CUDA_HOME/lib64"
ensure_link libcudart.so.13 "$CUDA_HOME/lib/libcudart.so"
ensure_link libcublasLt.so.13 "$CUDA_HOME/lib/libcublasLt.so"
ensure_link libcublas.so.13 "$CUDA_HOME/lib/libcublas.so"
for file in bin/nvcc include/cuda.h include/crt/host_config.h include/cccl/cuda/std/version include/cublasLt.h include/nvtx3/nvToolsExt.h nvvm/libdevice/libdevice.10.bc lib/libcudart.so.13 lib/libcublasLt.so.13; do
  [[ -f "$CUDA_HOME/$file" ]] || fail "Incomplete CUDA SDK: $file is missing. Rerun the locked CUDA package installation."
done
nvcc_version="$("$CUDA_HOME/bin/nvcc" --version)"
[[ "$nvcc_version" == *"V${runtime_values[3]}"* ]] || fail "The isolated nvcc does not match CUDA ${runtime_values[3]}."

# nvcc accepts only some host compiler versions (CUDA 13.3: GCC up to 15), which may be
# older than the system C++ compiler. Ask the pinned nvcc itself which candidate works.
probe="$(mktemp -d)"
printf '#include <concepts>\n#include <span>\n__global__ void k() {}\nint main() { k<<<1, 1>>>(); return 0; }\n' > "$probe/probe.cu"
candidates=()
if [[ -n "${CUDAHOSTCXX:-}" ]]; then
  candidates=("$CUDAHOSTCXX")
else
  candidates=("$CXX" g++-15 g++-14 g++-13 g++-12)
fi
CUDA_HOST_CXX=""
for candidate in "${candidates[@]}"; do
  path="$(command -v "$candidate")" || continue
  if "$CUDA_HOME/bin/nvcc" -ccbin "$path" -std=c++20 -arch=sm_${runtime_values[2]} -c "$probe/probe.cu" -o "$probe/probe.o" >/dev/null 2>&1; then
    CUDA_HOST_CXX="$path"
    break
  fi
done
rm -rf -- "$probe"
if [[ -z "$CUDA_HOST_CXX" ]]; then
  if [[ -n "${CUDAHOSTCXX:-}" ]]; then
    fail "CUDA ${runtime_values[3]} cannot compile C++20 with CUDAHOSTCXX=$CUDAHOSTCXX."
  fi
  fail "No C++20 host compiler that CUDA ${runtime_values[3]} accepts (it supports GCC up to 15). Install one (for example gcc15 on Arch, g++-14 on Debian/Ubuntu) or set CUDAHOSTCXX, then rerun."
fi
printf 'CUDA host compiler: %s\n' "$CUDA_HOST_CXX"

# The relative RPATH selects this repository's SDK. Neither the build nor the executable
# depends on another Python environment or a system CUDA toolkit.
if ! "$ROOT/.venv/bin/cmake" -S "$SOURCE" -B "$BUILD" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$ROOT/.venv/bin/ninja" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_CUDA_HOST_COMPILER="$CUDA_HOST_CXX" \
  -DCMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc" \
  -DCUDAToolkit_ROOT="$CUDA_HOME" \
  -DCUDA_cuda_driver_LIBRARY="$DRIVER_LIBRARY" \
  -DCMAKE_CUDA_ARCHITECTURES="${runtime_values[2]}" \
  -DCMAKE_BUILD_TYPE="${runtime_values[4]}" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  '-DCMAKE_INSTALL_RPATH=$ORIGIN/../../../../.cuda-toolkit/nvidia/cu13/lib' \
  -DFNGINE_BUILD_TESTS=OFF -DFNGINE_BUILD_BENCH=OFF; then
  fail 'CMake configuration failed. Check the error above, the C++20/CUDA host compilers and liburing. If this build directory belongs to another toolchain or location, move runtime/fngine/build aside and rerun; it was not deleted.'
fi
"$ROOT/.venv/bin/cmake" --build "$BUILD" --target fngine-serve --parallel "${runtime_values[5]}"
printf '\nBuilt the native server.\nNext: .venv/bin/python scripts/download_models.py\nThen: bash scripts/serve.sh\n'
