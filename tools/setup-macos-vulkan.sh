#!/usr/bin/env bash
#
# setup-macos-vulkan.sh — install this MoltenVK build as a private Vulkan driver.
#
# Scope is MoltenVK and nothing else. Prerequisites (Homebrew packages, Open Image
# Denoise, Xcode) are listed in the README and are yours to install; this script does
# not manage them.
#
#   ./tools/setup-macos-vulkan.sh              # install driver + set environment
#   ./tools/setup-macos-vulkan.sh --check      # report state, change nothing
#   ./tools/setup-macos-vulkan.sh --uninstall  # remove everything it installed
#
# See docs/macos-vulkan-setup.md for the reasoning and troubleshooting.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Defaults to the binary published in this repository. Set GLIM_MOLTENVK_URL="" to
# build from source instead.
PREBUILT_URL="${GLIM_MOLTENVK_URL-https://raw.githubusercontent.com/owlboy/glim-moltenvk-dist/main/libMoltenVK.dylib}"
PREBUILT_SHA256="${GLIM_MOLTENVK_SHA256-ec080b0feb76ea52a2bce0af0c0e9ccead2357e63af22027a12375e1cc6ecc04}"

# Ray query is not upstream yet; pinned to the PR branch as there is no release.
MOLTENVK_REPO="${GLIM_MOLTENVK_REPO:-https://github.com/dttdrv/MoltenVK.git}"
MOLTENVK_BRANCH="${GLIM_MOLTENVK_BRANCH:-macgaming/ray-query-pr}"
MOLTENVK_PR_URL="https://github.com/KhronosGroup/MoltenVK/pull/2771"

PREFIX="${GLIM_VULKAN_PREFIX:-$HOME/.local/lib/glim-vulkan}"
DYLIB="$PREFIX/libMoltenVK.dylib"
SRC_DIR="${GLIM_MOLTENVK_SRC:-$HOME/.cache/glim/MoltenVK}"
ICD_DIR="${GLIM_ICD_DIR:-$HOME/.local/share/vulkan/icd.d}"

# Overridable so a scoped install cannot reach into a real one.
LOADER_LINK="${GLIM_LOADER_LINK:-$HOME/lib/libvulkan.dylib}"

# Pins the loader to this driver. A stock molten-vk elsewhere on the search path is
# otherwise enumerated too, and Glim only checks for ray query on DISCRETE_GPU while
# Apple Silicon reports INTEGRATED_GPU — so the two tie and it takes whichever came
# first. VK_DRIVER_FILES is current; VK_ICD_FILENAMES is the legacy name.
DRIVER_FILES_VAR="VK_DRIVER_FILES"
LEGACY_DRIVER_FILES_VAR="VK_ICD_FILENAMES"
RAY_TRACING_VAR="MVK_CONFIG_ENABLE_EXPERIMENTAL_RAY_TRACING"
LOADER_VAR="GLIM_VULKAN_LOADER"

MODE="install"
WITH_LOADER=1
SET_GLOBAL=1
FORCE_REBUILD=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
else
  B=""; DIM=""; R=""; G=""; Y=""; N=""
fi

step() { printf "\n%s==>%s %s%s%s\n" "$B" "$N" "$B" "$*" "$N"; }
info() { printf "    %s\n" "$*"; }
ok()   { printf "    %s✓%s %s\n" "$G" "$N" "$*"; }
warn() { printf "    %s!%s %s\n" "$Y" "$N" "$*"; }
die()  { printf "\n%serror:%s %s\n" "$R" "$N" "$*" >&2; exit 1; }

# Self-contained rather than read from $0: the script is meant to be piped to bash,
# where there is no file to read a header comment out of.
usage() {
  cat <<'USAGE'
setup-macos-vulkan.sh — install this MoltenVK build as a private Vulkan driver.

  (no flags)      install driver + set environment
  --check         report state, change nothing
  --env           print the export lines
  --set-global    set the environment for GUI-launched apps
  --unset-global  clear it
  --no-global     install without setting the environment
  --loader-free   driver only, no loader stack
  --rebuild       force a fresh source build
  --uninstall     remove everything this installed
USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)         MODE="check" ;;
    --uninstall)     MODE="uninstall" ;;
    --env)           MODE="env" ;;
    --set-global)    MODE="set-global" ;;
    --unset-global)  MODE="unset-global" ;;
    --no-global)     SET_GLOBAL=0 ;;
    --loader-free)   WITH_LOADER=0 ;;
    --with-loader)   WITH_LOADER=1 ;;
    --rebuild)       FORCE_REBUILD=1 ;;
    -h|--help)       usage ;;
    *)               die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

using_prebuilt() { [[ -n "$PREBUILT_URL" ]]; }

# In loader mode Glim must load the Vulkan *loader*, not MoltenVK — pointing it at
# MoltenVK forces the direct path, which fails on Glim's unconditional
# VK_KHR_portability_enumeration. Only loader-free mode names the driver itself.
glim_loader_target() {
  if [[ $WITH_LOADER -eq 1 ]]; then printf '%s' "$LOADER_LINK"; else printf '%s' "$DYLIB"; fi
}

# ---------------------------------------------------------------------------
# Obtaining the driver
# ---------------------------------------------------------------------------

preflight() {
  step "Checking the machine"
  [[ "$(uname -s)" == "Darwin" ]] || die "macOS only (found $(uname -s))"
  ok "macOS $(sw_vers -productVersion) on $(uname -m)"

  if using_prebuilt; then
    [[ -n "$PREBUILT_SHA256" ]] || die "GLIM_MOLTENVK_URL is set but GLIM_MOLTENVK_SHA256 is not.
       Refusing to install an unverified binary."
    ok "using the published binary — no build toolchain needed"
    return
  fi

  info "no prebuilt configured — building MoltenVK from source"

  # The build drives xcodebuild against MoltenVK's own project, so the Command Line
  # Tools alone are not enough; a full Xcode must be selected.
  xcodebuild -version >/dev/null 2>&1 || die "xcodebuild not usable. Building from source needs full Xcode:
         sudo xcode-select -s /Applications/Xcode.app
         sudo xcodebuild -license accept"
  ok "$(xcodebuild -version | head -1)"
  command -v git >/dev/null || die "git not found"
}

# Fetches $1 to $2. Handles private GitHub repos, which answer an unauthenticated
# request with 404 rather than 401 — so a plain curl failure is not evidence the file
# is missing, and the authenticated paths must be tried before giving up.
download_artifact() {
  local url="$1" dest="$2"

  if curl -fsSL --retry 3 -o "$dest" "$url" 2>/dev/null; then return 0; fi

  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
    token="$(gh auth token 2>/dev/null || true)"
  fi

  if [[ -n "$token" ]]; then
    info "retrying with GitHub credentials"
    curl -fsSL --retry 3 -H "Authorization: Bearer $token" -o "$dest" "$url" 2>/dev/null && return 0
  fi

  if command -v gh >/dev/null 2>&1 && [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$ ]]; then
    local owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]}"
    local ref="${BASH_REMATCH[3]}" path="${BASH_REMATCH[4]}"
    info "retrying via gh api ($owner/$repo)"
    gh api "repos/$owner/$repo/contents/$path?ref=$ref" -H "Accept: application/vnd.github.raw" \
      > "$dest" 2>/dev/null && [[ -s "$dest" ]] && return 0
  fi

  return 1
}

fetch_prebuilt() {
  step "Downloading MoltenVK"
  info "$PREBUILT_URL"

  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  download_artifact "$PREBUILT_URL" "$tmp/libMoltenVK.dylib" \
    || die "download failed: $PREBUILT_URL

       If the source repository is private, authenticate first:
         gh auth login
       or export GITHUB_TOKEN with repo read access."

  local actual; actual="$(shasum -a 256 "$tmp/libMoltenVK.dylib" | awk '{print $1}')"
  [[ "$actual" == "$PREBUILT_SHA256" ]] || die "checksum mismatch — refusing to install
       expected $PREBUILT_SHA256
       actual   $actual"
  ok "sha256 verified"

  mkdir -p "$PREFIX"
  mv "$tmp/libMoltenVK.dylib" "$DYLIB"
  chmod 755 "$DYLIB"
}

build_from_source() {
  step "Fetching MoltenVK ($MOLTENVK_BRANCH)"
  info "ray query is not in upstream MoltenVK yet — $MOLTENVK_PR_URL"

  mkdir -p "$(dirname "$SRC_DIR")"
  if [[ -d "$SRC_DIR/.git" ]]; then
    git -C "$SRC_DIR" fetch --depth 1 origin "$MOLTENVK_BRANCH"
    git -C "$SRC_DIR" checkout -q FETCH_HEAD
  else
    git clone --depth 1 --branch "$MOLTENVK_BRANCH" "$MOLTENVK_REPO" "$SRC_DIR"
  fi
  ok "at $(git -C "$SRC_DIR" rev-parse --short HEAD)"

  local built="$SRC_DIR/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
  if [[ -f "$built" && $FORCE_REBUILD -eq 0 ]]; then
    ok "reusing existing build (--rebuild to force)"
  else
    step "Building MoltenVK"
    warn "15-40 minutes; compiles SPIRV-Cross and SPIRV-Tools from source"
    warn "a source build does NOT include patches/ — apply them first if you need them"
    ( cd "$SRC_DIR" && ./fetchDependencies --macos )
    ( cd "$SRC_DIR" && make macos )
    [[ -f "$built" ]] || die "build finished but $built is missing"
  fi

  mkdir -p "$PREFIX"
  cp "$built" "$DYLIB"
  info ""
  info "sha256: $(shasum -a 256 "$DYLIB" | awk '{print $1}')"
}

install_loader_stack() {
  step "Registering the driver"

  # is_portability_driver is required: loaders hide non-portability-aware drivers from
  # applications that have not opted in, and MoltenVK is not conformant.
  local icd_json
  icd_json=$(cat <<JSON
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "$DYLIB",
    "api_version": "1.3.0",
    "is_portability_driver": true
  }
}
JSON
)
  printf '%s\n' "$icd_json" > "$PREFIX/MoltenVK_icd.json"
  mkdir -p "$ICD_DIR"
  printf '%s\n' "$icd_json" > "$ICD_DIR/MoltenVK_icd.json"
  ok "ICD manifest at $ICD_DIR/MoltenVK_icd.json"

  # Ash asks dlopen for a bare libvulkan.dylib, which macOS resolves only against
  # DYLD_FALLBACK_LIBRARY_PATH — and Unity replaces that with its own Frameworks dir.
  # $HOME/lib is a default fallback entry, so it is found in both contexts.
  local loader=""
  for c in "$(brew --prefix vulkan-loader 2>/dev/null)/lib/libvulkan.dylib" \
           /opt/homebrew/lib/libvulkan.dylib /usr/local/lib/libvulkan.dylib; do
    [[ -f "$c" ]] && { loader="$c"; break; }
  done

  if [[ -n "$loader" ]]; then
    mkdir -p "$(dirname "$LOADER_LINK")"
    ln -sfn "$loader" "$LOADER_LINK"
    ok "$LOADER_LINK -> $loader"
  else
    die "libvulkan.dylib not found. Install the Vulkan loader first:
         brew install vulkan-loader"
  fi
}

# ---------------------------------------------------------------------------
# Verification, environment, teardown
# ---------------------------------------------------------------------------

verify() {
  step "Verifying"
  local failed=0

  [[ -f "$DYLIB" ]] || { warn "driver missing at $DYLIB"; return 1; }
  ok "driver present ($(du -h "$DYLIB" | awk '{print $1}'))"

  if nm -gU "$DYLIB" 2>/dev/null | grep -q "_vkGetInstanceProcAddr"; then
    ok "exports vkGetInstanceProcAddr"
  else
    warn "does not export vkGetInstanceProcAddr"; failed=1
  fi

  if ! command -v vulkaninfo >/dev/null 2>&1; then
    warn "vulkaninfo not found — skipping the ray query check (brew install vulkan-tools)"
    return $failed
  fi

  local tmpdir; tmpdir="$(mktemp -d)"
  cat > "$tmpdir/icd.json" <<JSON
{"file_format_version":"1.0.0","ICD":{"library_path":"$DYLIB","api_version":"1.3.0","is_portability_driver":true}}
JSON

  # The flag is not optional: MoltenVK keeps ray query behind it, so probing without
  # it reports a false negative on a perfectly good build.
  local out
  if out=$( VK_ICD_FILENAMES="$tmpdir/icd.json" VK_DRIVER_FILES="$tmpdir/icd.json" \
            MVK_CONFIG_ENABLE_EXPERIMENTAL_RAY_TRACING=1 vulkaninfo 2>/dev/null ); then
    if grep -q "VK_KHR_ray_query" <<<"$out"; then
      ok "VK_KHR_ray_query is advertised"
    else
      warn "VK_KHR_ray_query NOT advertised — wrong build?"; failed=1
    fi
  else
    warn "vulkaninfo could not run against this driver"; failed=1
  fi

  rm -rf "$tmpdir"
  return $failed
}

print_env() {
  printf 'export %s="%s"\n' "$LOADER_VAR" "$(glim_loader_target)"
  printf 'export %s=1\n' "$RAY_TRACING_VAR"
  if [[ $WITH_LOADER -eq 1 ]]; then
    printf 'export %s="%s"\n' "$DRIVER_FILES_VAR" "$ICD_DIR/MoltenVK_icd.json"
    printf 'export %s="%s"\n' "$LEGACY_DRIVER_FILES_VAR" "$ICD_DIR/MoltenVK_icd.json"
  fi
}

report_state() {
  local name v
  step "Current state"
  printf "    %-18s %s\n" "driver" "$( [[ -f "$DYLIB" ]] && echo "$DYLIB" || echo MISSING )"
  printf "    %-18s %s\n" "ICD manifest" "$( [[ -f "$ICD_DIR/MoltenVK_icd.json" ]] && echo present || echo "not installed" )"
  printf "    %-18s %s\n" "loader symlink" "$( [[ -e "$LOADER_LINK" ]] && echo present || echo "not installed" )"

  printf "\n%s    Global env (launchctl)%s\n" "$DIM" "$N"
  # `launchctl getenv` exits 0 with empty output for an unset variable rather than
  # failing, so emptiness is the only reliable test.
  for name in "$RAY_TRACING_VAR" "$LOADER_VAR" "$DRIVER_FILES_VAR"; do
    v="$(launchctl getenv "$name" 2>/dev/null || true)"
    printf "    %-44s %s\n" "$name" "${v:-unset}"
  done
}

set_global_env() {
  step "Setting the environment for GUI-launched apps"
  launchctl setenv "$LOADER_VAR" "$(glim_loader_target)"
  launchctl setenv "$RAY_TRACING_VAR" 1
  if [[ $WITH_LOADER -eq 1 ]]; then
    launchctl setenv "$DRIVER_FILES_VAR" "$ICD_DIR/MoltenVK_icd.json"
    launchctl setenv "$LEGACY_DRIVER_FILES_VAR" "$ICD_DIR/MoltenVK_icd.json"
  fi
  ok "set via launchctl — Unity Hub inherits these"
  info "machine-wide, persists until --unset-global"
}

unset_global_env() {
  step "Clearing the environment"
  local var
  for var in "$LOADER_VAR" "$RAY_TRACING_VAR" "$DRIVER_FILES_VAR" "$LEGACY_DRIVER_FILES_VAR"; do
    launchctl unsetenv "$var" 2>/dev/null || true
  done
  ok "cleared"
}

uninstall() {
  step "Removing what this script installed"
  rm -f "$ICD_DIR/MoltenVK_icd.json" && ok "removed ICD manifest (if any)"
  rm -rf "$PREFIX" && ok "removed $PREFIX"

  if [[ -L "$LOADER_LINK" ]] && [[ $WITH_LOADER -eq 1 ]]; then
    rm -f "$LOADER_LINK"; ok "removed loader symlink"
  elif [[ -e "$LOADER_LINK" ]]; then
    warn "$LOADER_LINK is not our symlink — left alone"
  fi

  # Ownership must be provable: --set-global always sets GLIM_VULKAN_LOADER, so if it
  # does not name this install, these globals are not ours to clear.
  local global_loader
  global_loader="$(launchctl getenv "$LOADER_VAR" 2>/dev/null || true)"
  if [[ "$global_loader" == "$DYLIB" || "$global_loader" == "$LOADER_LINK" ]]; then
    unset_global_env
  else
    warn "launchctl variables are not this install's — left alone"
  fi

  info ""
  info "Left alone: $SRC_DIR, and any Homebrew packages."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "$MODE" in
  check)        report_state; verify || true ;;
  env)          print_env ;;
  set-global)   [[ -f "$DYLIB" ]] || die "driver not installed"; set_global_env ;;
  unset-global) unset_global_env ;;
  uninstall)    uninstall ;;

  install)
    preflight
    if using_prebuilt; then fetch_prebuilt; else build_from_source; fi
    ok "installed $DYLIB"
    [[ $WITH_LOADER -eq 1 ]] && install_loader_stack

    if verify; then
      if [[ $SET_GLOBAL -eq 1 ]]; then
        set_global_env
      else
        step "Environment not set (--no-global)"
        print_env | sed 's/^/      /'
      fi
      step "Done"
      info "Restart Unity and Unity Hub, then bake."
    else
      step "Finished with warnings"
      warn "see above; docs/macos-vulkan-setup.md has a troubleshooting table"
      exit 1
    fi
    ;;
esac
