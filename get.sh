#!/usr/bin/env bash
# get.sh: install openset-llm with one command. No git clone and no compiler: it downloads the sources of the latest
# release and the engine built for that release, prepares the model, and adds an `openset-llm` command.
#
#   curl -fsSL https://raw.githubusercontent.com/opensetlabs/openset-llm/main/get.sh | bash
#
# Then:  openset-llm            # start the server and open the chat page (any ./serve option works: --port 9000)
#        openset-llm serve ...  # the server only
#        openset-llm check      # what this machine will get
#        openset-llm update     # move to the latest release
#
# Needs x86-64 Linux (or WSL2) with glibc 2.35 or newer (Ubuntu 22.04, Debian 12), curl, tar and python3.
# On anything else, build from source: see the README.
#
# Settings (environment): OPENSET_LLM_VERSION=v0.3.3 picks a release; OPENSET_LLM_APP is where the scripts go
# (default ~/.local/share/openset-llm); OPENSET_LLM_HOME is where the engine and the model go (default ~/.openset-llm);
# OPENSET_LLM_BIN_DIR is where the command goes (default ~/.local/bin).
set -euo pipefail

main() {
  local repo=https://github.com/opensetlabs/openset-llm
  local app=${OPENSET_LLM_APP:-$HOME/.local/share/openset-llm}
  local bindir=${OPENSET_LLM_BIN_DIR:-$HOME/.local/bin}
  local version=${OPENSET_LLM_VERSION:-}
  say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
  die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
  from_source="Build it from source instead: git clone $repo && cd openset-llm && ./start"

  [ "$(uname -s)" = Linux ] || die "this installer is for Linux (on Windows, run it inside WSL2). $from_source"
  case $(uname -m) in x86_64|amd64) ;; *) die "prebuilt engines exist for x86-64 only. $from_source" ;; esac
  for tool in curl tar python3; do command -v "$tool" >/dev/null 2>&1 || die "missing $tool; install it and run this again"; done
  local libc; libc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
  case $libc in
    '') die "this system does not use glibc, which the prebuilt engine needs. $from_source" ;;
    1.*|2.[0-9]|2.[12][0-9]|2.3[0-4]) die "glibc $libc is older than the prebuilt engine needs (2.35). $from_source" ;;
  esac

  if [ -z "$version" ]; then
    # the "latest" page redirects to the newest release tag
    version=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$repo/releases/latest") || die "could not reach $repo"
    version=${version##*/}
  fi
  case $version in v[0-9]*.[0-9]*.[0-9]*) ;; *) die "unexpected release name: $version" ;; esac

  say "Installing openset-llm $version into $app"
  mkdir -p "$(dirname "$app")" "$bindir"
  local stage; stage=$(mktemp -d "$app.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'" EXIT
  curl -fSL --retry 3 "${OPENSET_LLM_SOURCE_URL:-$repo/archive/refs/tags/$version.tar.gz}" | tar -xz -C "$stage" --strip-components=1 \
    || die "could not download the sources of $version"
  [ -f "$stage/install.sh" ] && [ -f "$stage/serve" ] && [ -f "$stage/start" ] || die "the download of $version is incomplete"
  grep -q -- '--prebuilt' "$stage/install.sh" || die "$version has no prebuilt engine (0.3.3 is the first release with one). $from_source"
  echo "$version" > "$stage/.version"

  # the engine attached to that same release, checked against its SHA256SUMS; the model comes from Hugging Face
  # (install.sh ends by saying how to start it from where it ran, which is a temporary folder here: leave that out)
  OPENSET_LLM_RELEASE_URL=${OPENSET_LLM_RELEASE_URL:-$repo/releases/download/$version} bash "$stage/install.sh" --prebuilt \
    | sed -e '/^Start it:/d' -e '/^Then chat:/d' \
    || die "the install did not finish (see the message above); nothing was changed in $app"

  # only now replace the previous scripts
  rm -rf "$app.previous"
  if [ -e "$app" ]; then mv "$app" "$app.previous"; fi
  mv "$stage" "$app"
  rm -rf "$app.previous"
  trap - EXIT

  cat > "$bindir/openset-llm" <<EOF
#!/bin/sh
# openset-llm: installed by get.sh. The scripts are in $app.
APP='$app'
case \${1:-start} in
  start)   [ \$# -gt 0 ] && shift; exec "\$APP/start" "\$@" ;;
  serve)   shift; exec "\$APP/serve" "\$@" ;;
  check)   exec "\$APP/install.sh" --check ;;
  version) cat "\$APP/.version" ;;
  update)  curl -fsSL https://raw.githubusercontent.com/opensetlabs/openset-llm/main/get.sh | bash ;;
  help|-h|--help)
    echo "openset-llm [start] [serve options]   start the server and open the chat page"
    echo "openset-llm serve [options]           the server only (openset-llm serve --help lists the options)"
    echo "openset-llm check | version | update" ;;
  *)       exec "\$APP/start" "\$@" ;;
esac
EOF
  chmod +x "$bindir/openset-llm"

  say "Done: openset-llm $version"
  case ":$PATH:" in
    *":$bindir:"*) echo "Start it:  openset-llm" ;;
    *) echo "Start it:  $bindir/openset-llm"
       echo "($bindir is not on your PATH. Add it, or open a new terminal if your system adds it at login.)" ;;
  esac
}

main "$@"
