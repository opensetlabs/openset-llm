#!/usr/bin/env bash
# install.sh: build (or fetch) the engine and download the model. Then run ./serve.
#
#   ./install.sh                 # CPU check, build for this machine, download + prepare the model
#   ./install.sh --portable      # build one binary set for every x86-64 CPU (picks the best kernel at run time:
#                                #   AVX-512 where the CPU has it, the 256-bit AVX2 / AVX-VNNI kernels where it does not)
#   ./install.sh --prebuilt      # fetch the engine built for the latest release instead of building (no compiler
#                                #   needed; checksum verified; must match this checkout's engine sources)
#   ./install.sh --bin-url URL   # fetch a prebuilt tarball (made by scripts/package.sh) instead of building
#   ./install.sh --no-mtp        # skip the speculative-decoding head (saves 1.4 GB of download; 1.4-1.9x slower)
#   ./install.sh --check         # only print what this machine will get, then exit
#   ./install.sh --model-only    # keep the engine already in $OPENSET_LLM_HOME/bin, just fetch + prepare the model
#
# Everything goes to $OPENSET_LLM_HOME (default ~/.openset-llm). Model weights come from Hugging Face; nothing is redistributed.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=${OPENSET_LLM_HOME:-$HOME/.openset-llm}
FORK_URL=https://github.com/PrismML-Eng/llama.cpp
FORK_SHA=e3de715222b2667c54a267441159a5729f11155e
HF=${HF_ENDPOINT:-https://huggingface.co}
BASE_REPO=prism-ml/Ternary-Bonsai-2-27B-gguf;  BASE_FILE=Ternary-Bonsai-2-27B-PTQ1_0.gguf
MTP_REPO=unsloth/Qwen3.8-27B-GGUF;             MTP_FILE=MTP/mtp-Qwen3.8-27B-Q4_0.gguf
MIN_RAM_KB=7600000      # an "8 GB" machine reports ~7.6-8.1 GB; the server's resident set is ~7.0 GB
MIN_DISK_GB=15          # base 6.0 + MTP sidecar 1.4 + grafted model 6.2 at peak, + the build

PORTABLE=0; BIN_URL=${OPENSET_LLM_BIN_URL:-}; MTP=1; CHECK_ONLY=0; MODEL_ONLY=0; PREBUILT=0; ENGINE_ID_ONLY=0
RELEASE_URL=${OPENSET_LLM_RELEASE_URL:-https://github.com/opensetlabs/openset-llm/releases/latest/download}
RELEASE_TARBALL=openset-llm-linux-x86_64.tar.gz
while [ $# -gt 0 ]; do
  case $1 in
    --portable) PORTABLE=1 ;;
    --prebuilt) PREBUILT=1 ;;
    --engine-id) ENGINE_ID_ONLY=1 ;;   # for scripts/package.sh: print what identifies the engine sources, then exit
    --bin-url) [ $# -ge 2 ] || { echo "--bin-url needs a URL" >&2; exit 2; }; BIN_URL=$2; shift ;;
    --no-mtp) MTP=0 ;;
    --check) CHECK_ONLY=1 ;;
    --model-only) MODEL_ONLY=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# What the engine is built from: the pinned fork commit, the patches and the kernels. Not this script, not the docs.
engine_id() { echo "$FORK_SHA $(cat "$HERE/patches/apply.sh" "$HERE"/patches/*.patch "$HERE"/kernels/* | cksum | cut -d' ' -f1)"; }
if [ "$ENGINE_ID_ONLY" = 1 ]; then engine_id; exit 0; fi
if [ "$PREBUILT" = 1 ]; then
  [ -z "$BIN_URL" ] || die "--prebuilt and --bin-url cannot be used together"
  [ "$PORTABLE" = 0 ] || die "--prebuilt and --portable cannot be used together"
  case $(uname -m) in x86_64|amd64) ;; *) die "prebuilt engines exist for x86-64 Linux only; run plain ./install.sh to build here" ;; esac
  BIN_URL=$RELEASE_URL/$RELEASE_TARBALL
fi

# ---------------------------------------------------------------- CPU check
cpu_path() {
  local arch flags; arch=$(uname -m)
  case $arch in
    x86_64|amd64)
      flags=" $(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2) "
      has() { case $flags in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
      if has avx512f && has avx512bw && has avx512_vnni && has avx512vbmi; then
        echo "fast|AVX-512 VNNI + VBMI: full fast path"
      elif has avx512f && has avx512bw && has avx512_vnni; then
        echo "partial|AVX-512 VNNI without VBMI: partial fast path (slower than the full one)"
      elif has avx512f && has avx2 && has fma && has f16c; then
        echo "avx2|AVX-512 without VNNI: the 256-bit kernels (not measured on this CPU class)"
      elif has avx2 && has fma && has f16c && has avx_vnni; then
        echo "avx2|AVX2 + AVX-VNNI, no AVX-512: the 256-bit kernels (checked under an emulated CPU of this kind; not measured on one yet)"
      elif has avx2 && has fma && has f16c; then
        echo "avx2|AVX2, no AVX-512: the 256-bit kernels (0.7x of the AVX-512 path's plain decoding speed on an Ice Lake server with AVX-512 disabled)"
      elif has avx2; then
        echo "fallback|AVX2 without FMA: the fork's own ternary kernel. It will run, slowly"
      else
        echo "fallback|no AVX2: the generic kernel. It will run, slowly"
      fi ;;
    aarch64|arm64) echo "fallback|ARM: builds and runs on the fork's own kernel; not yet tuned or measured" ;;
    *) echo "unsupported|$arch is not supported" ;;
  esac
}
[ "$(uname -s)" = Linux ] || die "Linux only for now (on a Mac, PrismML's Metal build is the faster choice)."
CPU=$(cpu_path); CPU_KIND=${CPU%%|*}
say "CPU: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ //' || uname -m)"
say "Path: ${CPU#*|}"
[ "$CPU_KIND" = unsupported ] && die "${CPU#*|}"

# ---------------------------------------------------------------- RAM / disk check
mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
if [ -r /sys/fs/cgroup/memory.max ]; then           # containers: the cgroup limit is what counts
  lim=$(cat /sys/fs/cgroup/memory.max)
  [ "$lim" != max ] && [ $((lim / 1024)) -lt "$mem_kb" ] && mem_kb=$((lim / 1024))
fi
say "RAM: $((mem_kb / 1024)) MiB"
if [ "$mem_kb" -lt "$MIN_RAM_KB" ]; then
  die "this needs a machine with at least 8 GB of RAM (found $((mem_kb / 1024)) MiB).
       The model alone is ~6 GB resident and the server needs close to 8 GB at its peak; below 8 GB it will be OOM-killed."
fi
[ "$CHECK_ONLY" = 1 ] && exit 0
mkdir -p "$PREFIX"/{bin,models}
free_gb=$(df -Pk "$PREFIX/models/" | awk 'NR==2 {print int($4/1048576)}')
have_gb=$(du -skL "$PREFIX/models" | awk '{print int($1/1048576)}')   # already-downloaded parts count
need=$((MIN_DISK_GB - have_gb)); [ "$need" -lt 2 ] && need=2
[ "$free_gb" -ge "$need" ] || die "need ~${need} GB free disk under $PREFIX (found ${free_gb} GB). Set OPENSET_LLM_HOME to put it elsewhere."

# ---------------------------------------------------------------- tools
SUDO=; [ "$(id -u)" = 0 ] || { command -v sudo >/dev/null && sudo -n true 2>/dev/null && SUDO=sudo; }
apt_install() { [ -n "$SUDO" ] || [ "$(id -u)" = 0 ] || return 1; command -v apt-get >/dev/null || return 1
  $SUDO apt-get update -qq && DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq "$@" >/dev/null; }
need_tools=()
command -v curl >/dev/null || need_tools+=(curl)
command -v python3 >/dev/null || need_tools+=(python3)
BUILD=1; { [ -n "$BIN_URL" ] || [ "$MODEL_ONLY" = 1 ]; } && BUILD=0
NEED_GIT=$BUILD
if [ "$MTP" = 1 ] && [ ! -f "$PREFIX/models/model.gguf" ] && [ ! -d "$PREFIX/llama.cpp/gguf-py" ]; then NEED_GIT=1; fi
if [ "$NEED_GIT" = 1 ]; then command -v git >/dev/null || need_tools+=(git); fi
if [ "$BUILD" = 1 ]; then
  command -v cmake >/dev/null || need_tools+=(cmake)
  command -v c++ >/dev/null || need_tools+=(build-essential)
  command -v ninja >/dev/null || need_tools+=(ninja-build)
fi
if [ ${#need_tools[@]} -gt 0 ]; then
  say "Installing: ${need_tools[*]}"
  apt_install "${need_tools[@]}" || true
fi
PY=python3
# the MTP graft reads GGUF (gguf-py: numpy, pyyaml). It runs as python3 -I below, which sees neither the user's
# site-packages (pip install --user) nor PYTHONPATH, so look for the modules the same way
if [ "$MTP" = 1 ] && [ ! -f "$PREFIX/models/model.gguf" ] && ! python3 -I -c 'import numpy, yaml' 2>/dev/null; then
  say "Setting up a Python venv with numpy + pyyaml (to attach the multi-token-prediction head)"
  if python3 -m venv "$PREFIX/venv" >/dev/null 2>&1 || { apt_install python3-venv && python3 -m venv "$PREFIX/venv"; }; then
    "$PREFIX/venv/bin/pip" install -q numpy pyyaml && PY=$PREFIX/venv/bin/python
  else
    apt_install python3-numpy python3-yaml || die "need numpy + pyyaml for the MTP graft: install python3-numpy python3-yaml, or rerun with --no-mtp"
  fi
fi
if [ "$BUILD" = 1 ] && ! command -v cmake >/dev/null; then   # no apt/sudo: cmake + ninja from PyPI
  [ "$PY" = python3 ] && { python3 -m venv "$PREFIX/venv" && PY=$PREFIX/venv/bin/python; }
  "$PREFIX/venv/bin/pip" install -q cmake ninja && export PATH="$PREFIX/venv/bin:$PATH"
fi
for t in curl python3; do command -v $t >/dev/null || die "missing $t"; done
if [ "$NEED_GIT" = 1 ]; then command -v git >/dev/null || die "missing git; install git to build the engine or fetch the MTP reader"; fi
if [ "$BUILD" = 1 ]; then for t in cmake c++; do command -v $t >/dev/null || die "missing $t. On Ubuntu or Debian: sudo apt install -y build-essential cmake git (or use --bin-url)"; done; fi

# ---------------------------------------------------------------- engine
SRC=$PREFIX/llama.cpp
begin_bin_update() {
  BIN_STAGE=$(mktemp -d "$PREFIX/.bin.XXXXXX")
  BIN_PREVIOUS=$BIN_STAGE.previous
  cleanup_bin_update() {
    local update_status=$?
    trap - EXIT
    trap '' INT TERM
    if [ -d "$BIN_PREVIOUS" ] && [ ! -e "$PREFIX/bin" ]; then
      if ! mv "$BIN_PREVIOUS" "$PREFIX/bin"; then
        echo "could not restore the previous engine; binaries remain in $BIN_PREVIOUS" >&2
        [ "$update_status" != 0 ] || update_status=1
      fi
    fi
    if ! rm -rf "$BIN_STAGE"; then
      echo "could not remove the staging directory $BIN_STAGE" >&2
      [ "$update_status" != 0 ] || update_status=1
    fi
    exit "$update_status"
  }
  trap cleanup_bin_update EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

publish_bin_update() {
  mv "$PREFIX/bin" "$BIN_PREVIOUS"
  if mv "$BIN_STAGE" "$PREFIX/bin"; then
    :
  else
    update_status=$?
    echo "could not publish the engine; restoring the previous binaries" >&2
    exit "$update_status"
  fi
  rm -rf "$BIN_PREVIOUS"
  trap - EXIT INT TERM
}

if [ "$MODEL_ONLY" = 1 ]; then
  :
elif [ -n "$BIN_URL" ]; then
  say "Fetching prebuilt binaries: $BIN_URL"
  begin_bin_update
  if [ "$PREBUILT" = 1 ]; then
    # download to a file first: the checksum is checked before anything is unpacked or run
    curl -fSL --retry 3 -o "$BIN_STAGE/.download" "$BIN_URL" \
      || die "could not download $BIN_URL
       Releases before 0.3.3 carry no prebuilt engine. Run plain ./install.sh to build the engine here instead."
    sums=$(curl -fsSL --retry 3 "$RELEASE_URL/SHA256SUMS") || die "could not download $RELEASE_URL/SHA256SUMS"
    want=$(printf '%s\n' "$sums" | awk -v f="$RELEASE_TARBALL" '$2 == f || $2 == "*" f {print $1; exit}')
    got=$(sha256sum "$BIN_STAGE/.download" | cut -d' ' -f1)
    [ -n "$want" ] && [ "$want" = "$got" ] || die "checksum mismatch for $RELEASE_TARBALL (expected ${want:-no entry in SHA256SUMS}, got $got); nothing was installed"
    tar -xzf "$BIN_STAGE/.download" -C "$BIN_STAGE" --strip-components=1 || die "could not unpack $BIN_URL"
    rm -f "$BIN_STAGE/.download"
    if [ "$(cat "$BIN_STAGE/.engine-id" 2>/dev/null)" != "$(engine_id)" ]; then
      die "the latest release's engine was built from different engine sources than this checkout (patches or kernels differ).
       Check out the latest release tag, or run plain ./install.sh to build the engine here."
    fi
  else
    curl -fSL --retry 3 "$BIN_URL" | tar -xz -C "$BIN_STAGE" --strip-components=1 \
      || die "could not download or unpack $BIN_URL"
  fi
  # a prebuilt engine only runs on the distribution it was built on or a newer one: find out now, before the download
  engine_starts() { ver=$(LD_LIBRARY_PATH="$BIN_STAGE" "$BIN_STAGE/llama-server" --version 2>&1); }
  if ! engine_starts && case $ver in *libgomp.so.1*) true ;; *) false ;; esac; then
    say "Installing: libgomp1"; apt_install libgomp1 || true   # the one runtime library a bare system often lacks
  fi
  if ! engine_starts; then
    printf '%s\n' "$ver" | head -6 >&2
    die "the prebuilt engine cannot start on this system (the loader's reason is above).
       A missing library or a 'version ... not found' line means it was built on a newer distribution than this one.
       Run plain ./install.sh to build the engine here instead."
  fi
  publish_bin_update
else
  stamp="$FORK_SHA portable=$PORTABLE $(cat "$HERE/install.sh" "$HERE/patches/apply.sh" "$HERE"/patches/*.patch "$HERE"/kernels/* | cksum | cut -d' ' -f1)"
fi
if [ "$BUILD" = 1 ] && [ -x "$PREFIX/bin/llama-server" ] && [ "$(cat "$PREFIX/bin/.stamp" 2>/dev/null)" = "$stamp" ]; then
  say "Engine already built for this source; skipping the build"
elif [ "$BUILD" = 1 ]; then
  if [ ! -d "$SRC/.git" ]; then
    say "Cloning PrismML llama.cpp @ ${FORK_SHA:0:7}"
    for try in 1 2 3; do   # GitHub drops a connection now and then
      rm -rf "$SRC"; git clone -q "$FORK_URL" "$SRC" && break
      [ "$try" = 3 ] && die "could not clone $FORK_URL after 3 tries; check the network and run this again"
      sleep 5
    done
  fi
  git -C "$SRC" checkout -q "$FORK_SHA"
  sh "$HERE/patches/apply.sh" "$SRC"
  gen=(); command -v ninja >/dev/null && gen=(-G Ninja)
  common=(-DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF)
  if [ "$PORTABLE" = 1 ]; then
    say "Building (portable: every x86-64 kernel variant, chosen at run time)"
    flags=(-DGGML_NATIVE=OFF -DBUILD_SHARED_LIBS=ON -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON
           -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON "-DCMAKE_INSTALL_RPATH=\$ORIGIN")
  else
    say "Building for this CPU (-march=native)"
    flags=(-DGGML_NATIVE=ON -DBUILD_SHARED_LIBS=OFF)
  fi
  rm -rf "$SRC/build"
  cmake -S "$SRC" -B "$SRC/build" "${gen[@]}" "${common[@]}" "${flags[@]}" >"$PREFIX/build.log" 2>&1 \
    || { tail -20 "$PREFIX/build.log"; die "cmake configure failed (log: $PREFIX/build.log)"; }
  # containers: nproc can be the host's thread count (seen: 64 under an 8-CPU, 16 GB limit), and 64 compilers OOM
  # the box. Cap the jobs by the cgroup CPU quota and by ~1 GiB of free memory per job.
  jobs=$(nproc)
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r q p < /sys/fs/cgroup/cpu.max
    [ "$q" != max ] && [ $(( (q + p - 1) / p )) -lt "$jobs" ] && jobs=$(( (q + p - 1) / p ))
  fi
  free_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  if [ -r /sys/fs/cgroup/memory.max ] && [ "$(cat /sys/fs/cgroup/memory.max)" != max ]; then
    cg_kb=$(( ($(cat /sys/fs/cgroup/memory.max) - $(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)) / 1024 ))
    [ "$cg_kb" -lt "$free_kb" ] && free_kb=$cg_kb
  fi
  [ $((free_kb / 1048576)) -lt "$jobs" ] && jobs=$((free_kb / 1048576))
  [ "$jobs" -lt 1 ] && jobs=1
  cmake --build "$SRC/build" -j "$jobs" >>"$PREFIX/build.log" 2>&1 \
    || { tail -30 "$PREFIX/build.log"; die "build failed (log: $PREFIX/build.log)"; }
  begin_bin_update
  cp -a "$SRC/build/bin/llama-server" "$BIN_STAGE/"
  for artifact in "$SRC/build/bin/llama-bench" "$SRC/build/bin/llama-cli" "$SRC"/build/bin/*.so*; do
    [ -e "$artifact" ] || continue
    cp -a "$artifact" "$BIN_STAGE/"
  done
  echo "$stamp" > "$BIN_STAGE/.stamp"
  if ! LD_LIBRARY_PATH="$BIN_STAGE" "$BIN_STAGE/llama-server" --version >>"$PREFIX/build.log" 2>&1; then
    die "the built engine cannot start (log: $PREFIX/build.log); keeping the previous engine"
  fi
  publish_bin_update
fi
[ -x "$PREFIX/bin/llama-server" ] || die "no llama-server in $PREFIX/bin"

# ---------------------------------------------------------------- model
M=$PREFIX/models
# A model starts like one: a GGUF file begins with the magic (the format version follows it). curl's exit status
# and byte count say nothing about the body; a proxy or a mirror that answers with a sign-in or error page looks
# like a finished download, and the file it wrote would be published as the model.
gguf_ok() {   # file
  [ "$(head -c 4 "$1" 2>/dev/null)" = GGUF ]
}
get() {   # repo file dest
  [ -f "$3" ] && return 0
  say "Downloading $1/$2"
  local auth=(); [ -n "${HF_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $HF_TOKEN")
  if curl -fL --retry 5 -C - "${auth[@]}" -o "$3.part" "$HF/$1/resolve/main/$2"; then
    :
  else
    download_status=$?
    if [ "$download_status" = 33 ]; then
      say "The server does not support resuming $2; restarting the download"
      curl -fL --retry 5 "${auth[@]}" -o "$3.part" "$HF/$1/resolve/main/$2" \
        || die "the download of $2 failed; run ./install.sh again to resume it"
    else
      die "the download of $2 failed; run ./install.sh again to resume it"
    fi
  fi
  if ! gguf_ok "$3.part"; then
    rm -f "$3.part"
    die "$2 is not a GGUF model file: the download from $HF/$1/resolve/main/$2 did not start with a model header.
       A proxy, a mirror or a captive network can send a web page instead of the file.
       The partial download was removed; run ./install.sh again to fetch it, or try another network."
  fi
  mv "$3.part" "$3"
}
if [ ! -f "$M/model.gguf" ]; then
  get "$BASE_REPO" "$BASE_FILE" "$M/base.gguf"
  if [ "$MTP" = 1 ]; then
    get "$MTP_REPO" "$MTP_FILE" "$M/mtp-sidecar.gguf"
    if [ ! -d "$SRC/gguf-py" ]; then   # --bin-url: fetch just the pinned fork's gguf-py (it knows the PTQ1_0 type)
      git init -q "$PREFIX/gguf-src" && git -C "$PREFIX/gguf-src" fetch -q --depth 1 "$FORK_URL" "$FORK_SHA" \
        && git -C "$PREFIX/gguf-src" checkout -q FETCH_HEAD || die "could not fetch gguf-py (needs git)"
      SRC=$PREFIX/gguf-src
    fi
    say "Attaching the multi-token-prediction (MTP) head to the model (for speculative decoding)"
    "$PY" -I "$HERE/scripts/graft_mtp.py" --gguf-py "$SRC/gguf-py" "$M/base.gguf" "$M/mtp-sidecar.gguf" "$M/model.gguf.part"
    mv "$M/model.gguf.part" "$M/model.gguf"
    rm -f "$M/base.gguf" "$M/mtp-sidecar.gguf" "$M/no-mtp"
    rm -rf "$PREFIX/gguf-src"
  else
    mv "$M/base.gguf" "$M/model.gguf"
    touch "$M/no-mtp"
  fi
fi

say "Done. $(du -sh "$M/model.gguf" | cut -f1) model in $M"
echo "Start it:           $HERE/serve"
echo "Then chat:          open http://127.0.0.1:8080 in a browser   (API for code: http://127.0.0.1:8080/v1)"
