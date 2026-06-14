#!/usr/bin/env bash
# forge.sh - Cozy, direct rebuild script for ungoogled-chromium macOS.
#
# Usage:
#   ./forge.sh
#
# Help:
#   ./forge.sh -h
#   ./forge.sh --help
#
# Assumptions for this particular local build workspace:
#   - This script lives at the root of the wrapper project directory.
#   - All project paths are resolved from the directory containing this script,
#     so the workspace can live anywhere on disk.
#   - forge.conf, version.txt, and flags.macos.gn are the local authored control
#     files for this build. They live beside this script, outside the checkout
#     that gets refreshed every run.
#   - ungoogled-chromium-macos/ is a managed checkout that this script owns. It
#     gets recreated from upstream whenever ./forge.sh runs.
#   - build/ under that managed checkout is generated state. Nothing in that
#     directory is hand-authored; it is made by the build and safe to clear.
#   - patches.local/ is the local custom patch layer. It lives outside the
#     refreshed checkout so local choices stay with this workspace.
#   - Full Xcode, Homebrew tooling, Python, git, curl, greadlink, and ninja are
#     already installed and available to this shell.
#   - Network access is expected. This script clones the small macOS wrapper
#     repo, then downloads the official Chromium source archive plus platform
#     toolchain resources. It intentionally does not use Chromium's heavier
#     gclient clone path for source retrieval.
#
# Rebuild philosophy:
#   This script is deliberately direct. A clean rebuild should begin from inputs
#   it can explain: a newly cloned wrapper repo, a published release tag, known
#   source archives, and local files that live beside this script. Running
#   ./forge.sh means: refresh the managed checkout, pin it to the latest release
#   tag, restore build inputs from known release archives, generate build files,
#   and build.
#
# Patch philosophy:
#   Patches should be named little choices, not surprises. Upstream
#   ungoogled-chromium patches remove the big Google integration surface. macOS
#   patches make that source build correctly on this platform. Local custom
#   patches are where workspace preferences live; every local patch should have
#   a plain-English note in patches.local/manifest.tsv so the terminal can teach
#   while it builds.
#
# Safety boundary:
#   Power-user rebuilds still get a tidy workbench. Cleanup is limited to the
#   project-owned managed checkout and its generated build state. This script
#   does not touch home directories, system folders, mounted-volume roots,
#   credentials, SSH keys, logs, this script, forge.conf, version.txt, or
#   flags.macos.gn. The path checks are quiet rails, not pause-and-ask steps:
#   they keep the cleanup boundary inside this project.
#
set -euo pipefail

# Make unmatched globs behave like bash when running under zsh.
if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt NONOMATCH
fi

SCRIPT_SELF="$0"
if [[ -n "${BASH_VERSION:-}" ]]; then
    SCRIPT_SELF="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
    # shellcheck disable=SC2296 # zsh-only prompt expansion for the script path.
    SCRIPT_SELF="${(%):-%N}"
fi

SCRIPT_DIR="$(cd "$(dirname -- "${SCRIPT_SELF}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/forge.conf"
LOG_DIR="${SCRIPT_DIR}/out/logs"
VERSION_FILE="${SCRIPT_DIR}/version.txt"
LAST_BUILT_VERSION_FILE="${SCRIPT_DIR}/.forge-last-built-version"

REPO_DIR="${SCRIPT_DIR}/ungoogled-chromium-macos"
REPO_URL="https://github.com/ungoogled-software/ungoogled-chromium-macos.git"
BUILD_DIR="${REPO_DIR}/build"
SRC_DIR="${BUILD_DIR}/src"
MAIN_REPO="${REPO_DIR}/ungoogled-chromium"
DOWNLOAD_CACHE="${BUILD_DIR}/download_cache"

FLAGS_BASE="${MAIN_REPO}/flags.gn"
FLAGS_MACOS="${SCRIPT_DIR}/flags.macos.gn"
FLAGS_OUTPUT="${SRC_DIR}/out/Default/args.gn"

LOCAL_PATCHES_DIR="${SCRIPT_DIR}/patches.local"
LOCAL_PATCHES_SERIES="${LOCAL_PATCHES_DIR}/series"
LOCAL_PATCHES_MANIFEST="${LOCAL_PATCHES_DIR}/manifest.tsv"

RETRIEVE_SCRIPT="${REPO_DIR}/retrieve_and_unpack_resource.sh"
SIGN_SCRIPT="${REPO_DIR}/sign_and_package_app.sh"

UNGOOGLED_RELEASES_API="https://api.github.com/repos/ungoogled-software/ungoogled-chromium-macos/releases/latest"

LOG_FILE=""
JOBS=""
ARCH=""
ARCH_GN=""
ARCH_RESOURCE=""
VERSION=""
LATEST_TAG=""
LATEST_VERSION=""
CHECK_ONLY=""

log_init() {
    mkdir -p "${LOG_DIR}"
    LOG_FILE="${LOG_DIR}/forge_$(date +%Y%m%d_%H%M%S).log"

    # Keep the console readable while also preserving an audit trail. Chromium
    # builds are long enough that "what happened eight hours ago?" should be
    # answerable from a log file, not memory.
    if ! exec > >(tee -a "${LOG_FILE}") 2>&1; then
        exec >> "${LOG_FILE}" 2>&1
    fi

    echo "[forge] started: $(date)"
    echo "[forge] log: ${LOG_FILE}"
}

section() {
    echo ""
    echo "[forge] $*"
}

info() {
    echo "[forge] $*"
}

explain() {
    echo "[forge] why: $*"
}

warn() {
    echo "[forge] warning: $*" >&2
}

error() {
    echo "[forge] error: $*" >&2
    exit 1
}

success() {
    echo "[forge] $*"
}

print_shell_telemetry() {
    if [[ "${DEBUG:-0}" != "1" ]] && [[ "${VERBOSE:-0}" != "1" ]]; then
        return
    fi

    if [[ -n "${BASH_VERSION:-}" ]]; then
        info "Shell: bash ${BASH_VERSION}"
    elif [[ -n "${ZSH_VERSION:-}" ]]; then
        info "Shell: zsh ${ZSH_VERSION}"
    else
        info "Shell: ${SHELL:-<unknown>}"
    fi

    info "SCRIPT_SELF=${SCRIPT_SELF}"
    info "SCRIPT_DIR=${SCRIPT_DIR}"
}

print_help() {
    cat <<EOF
Usage:
  ./forge.sh

Update check (no cleanup, no checkout refresh, no build):
  ./forge.sh --check
    Validates the workbench, confirms local version files agree, then queries
    the ungoogled-chromium-macos GitHub releases API for the latest tag and
    compares it against the last verified local build (recorded in
    .forge-last-built-version on every successful ./forge.sh run). Prints
    "current" or "update available" and exits 0 either way; nonzero only on
    actual errors (missing tools, network failure, inconsistent local files).

Help:
  ./forge.sh -h
  ./forge.sh --help

What this script does:
  forge.sh is the one-button local rebuild script for this ungoogled-chromium
  macOS build workspace. It assumes you want a freshly refreshed checkout every
  time you run it, with the local recipe files kept beside this script.

What it applies to:
  Paths are resolved at runtime from the directory containing forge.sh, so this
  workspace can live anywhere on disk.

  Script directory:
    ${SCRIPT_DIR}

  Repo checkout managed by this script:
    ${REPO_DIR}

  Upstream macOS repo:
    ${REPO_URL}

What happens when you run ./forge.sh:
  1. Validate host tools, local helper files, and local version markers.
  2. Clear the existing managed ungoogled-chromium-macos checkout.
  3. Clone a newly refreshed ungoogled-chromium-macos checkout.
  4. Fetch the latest release metadata from GitHub.
  5. Update forge.conf and version.txt to the latest Chromium version.
  6. Check out the latest release tag and initialize submodules.
  7. Clear generated build state inside the refreshed checkout.
  8. Download and unpack the Chromium source archive and resources.
  9. Apply ungoogled-chromium patches, macOS patches, local custom patches,
     and domain substitutions.
  10. Generate args.gn from upstream flags plus flags.macos.gn.
  11. Download platform-specific LLVM, Rust, and Node resources.
  12. Bootstrap GN, build bindgen, generate build files, and run Ninja.
  13. Build Chromium.app and chromedriver.
  14. Sign/package only if MACOS_CERTIFICATE_NAME is configured.
  15. Verify Chromium.app and chromedriver exist.

Local custom patches:
  Local patches live beside this script, outside the checkout that gets
  refreshed every run, so your workspace choices stay easy to find:
    ${LOCAL_PATCHES_DIR}

  Add patch filenames to:
    ${LOCAL_PATCHES_SERIES}

  Explain each patch in tab-separated plain English:
    ${LOCAL_PATCHES_MANIFEST}

What gets refreshed:
  Local changes inside the managed checkout are intentionally cleared:
    ${REPO_DIR}

What stays beside the script:
  The script, config, version file, macOS flags, and logs stay outside the
  managed checkout cleanup:
    ${SCRIPT_DIR}/forge.sh
    ${CONF_FILE}
    ${VERSION_FILE}
    ${FLAGS_MACOS}
    ${LOG_DIR}

Notes:
  Ninja jobs are chosen automatically using a conservative CPU-based default
  suitable for unattended or overnight builds.
  The repo refresh still has exact-path rails and stops before cleanup if the
  target path is not exactly the expected checkout directory.
EOF
}

usage() {
    print_help >&2
    exit 1
}

show_help_and_exit() {
    print_help
    exit 0
}

get_default_jobs() {
    local logical_cpu jobs

    # This is an overnight-build script, not a "pin every core at lunch" script.
    # Pick a conservative automatic Ninja count so the machine remains usable
    # and thermal throttling is less likely to turn speed into heat theater.
    if logical_cpu="$(sysctl -n hw.logicalcpu 2>/dev/null)" && [[ "${logical_cpu}" =~ ^[0-9]+$ ]] && (( logical_cpu > 0 )); then
        jobs=$(( logical_cpu / 2 ))
        if (( jobs < 2 )); then
            jobs=2
        fi
        if (( jobs > 8 )); then
            jobs=8
        fi
        echo "${jobs}"
        return
    fi

    echo "4"
}

parse_args() {
    JOBS="$(get_default_jobs)"

    # There is intentionally no build-mode menu here. ./forge.sh is the build.
    # Help is allowed because documentation should be close at hand. --check is
    # a read-only preflight that runs validation and exits without touching the
    # workspace. Any other option exits before workspace cleanup begins.
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            -h|--help)
                show_help_and_exit
                ;;
            --check)
                CHECK_ONLY=1
                shift
                ;;
            *)
                usage
                ;;
        esac
    done
}

require_command() {
    local command_name="${1}"
    command -v "${command_name}" >/dev/null 2>&1 || error "Required command not found: ${command_name}"
}

require_file() {
    local file_path="${1}"
    [[ -f "${file_path}" ]] || error "Required file is missing: ${file_path}"
}

require_dir() {
    local dir_path="${1}"
    [[ -d "${dir_path}" ]] || error "Required directory is missing: ${dir_path}"
}

require_executable() {
    local file_path="${1}"
    [[ -x "${file_path}" ]] || error "Required executable is missing or not executable: ${file_path}"
}

report_tree_sample() {
    local target_path="${1}"

    if [[ ! -e "${target_path}" ]]; then
        return
    fi

    find "${target_path}" -mindepth 1 | sed -n '1,40p' || true
}

is_git_worktree() {
    local repo_dir="${1}"
    git -C "${repo_dir}" rev-parse --git-dir >/dev/null 2>&1
}

validate_host_layout() {
    section "checking the workbench"
    explain "make sure the machine and local recipe files are ready before the checkout is refreshed"

    # Check the local workbench before touching the managed checkout. If a tool
    # or local recipe file is missing, stopping here keeps the rebuild tidy and
    # easy to understand.
    require_command curl
    require_command git
    require_command greadlink
    require_command ninja
    require_command python3

    require_file "${CONF_FILE}"
    require_file "${VERSION_FILE}"
    require_file "${FLAGS_MACOS}"
    require_dir "${LOCAL_PATCHES_DIR}"
    require_file "${LOCAL_PATCHES_SERIES}"
    require_file "${LOCAL_PATCHES_MANIFEST}"

    info "Script directory: ${SCRIPT_DIR}"
    info "Config file: ${CONF_FILE}"
    info "Version file: ${VERSION_FILE}"
    info "Build flags: ${FLAGS_MACOS}"
    info "Local patches: ${LOCAL_PATCHES_DIR}"
}

validate_repo_layout() {
    section "checking refreshed repo layout"
    explain "confirm the new checkout has the helper scripts and git metadata this workflow depends on"

    # After cloning, validate the exact upstream shape we depend on. This keeps
    # upstream layout changes near the top of the log instead of hiding them
    # halfway through source retrieval or patching.
    require_dir "${REPO_DIR}"
    require_executable "${RETRIEVE_SCRIPT}"

    is_git_worktree "${REPO_DIR}" || error "Expected a git checkout at ${REPO_DIR}"

    info "Repo directory: ${REPO_DIR}"
    info "Retrieve script: ${RETRIEVE_SCRIPT}"
    success "Repo directory is a git worktree"
}

safe_remove_repo_dir() {
    local target="${REPO_DIR}"
    local expected="${SCRIPT_DIR}/ungoogled-chromium-macos"
    local target_basename

    # These checks are quiet rails. The script is allowed to refresh exactly one
    # directory: the managed checkout beside this file. If the workspace shape
    # is different, stop before cleanup starts.
    [[ -n "${target}" ]] || error "Stopping before repo cleanup: target path is empty."
    [[ "${target}" = /* ]] || error "Stopping before repo cleanup: target path is not absolute: ${target}"
    [[ "${target}" != "/" ]] || error "Stopping before repo cleanup: target path is /."
    [[ "${target}" != "${SCRIPT_DIR}" ]] || error "Stopping before repo cleanup: target path is SCRIPT_DIR: ${target}"
    [[ "${target}" == "${expected}" ]] || error "Stopping before repo cleanup: expected ${expected}, got ${target}"

    target_basename="$(basename "${target}")"
    [[ "${target_basename}" == "ungoogled-chromium-macos" ]] || error "Stopping before repo cleanup: unexpected basename ${target_basename}"
    [[ ! -e "${target}" || -d "${target}" ]] || error "Stopping before repo cleanup: target exists but is not a directory: ${target}"

    if [[ ! -e "${target}" ]]; then
        info "No existing managed checkout to clear: ${target}"
        return
    fi

    info "Clearing managed checkout: ${target}"
    rm -rf "${target}"

    [[ ! -e "${target}" ]] || error "Could not finish repo cleanup: ${target}"
    success "Managed checkout cleared: ${target}"
}

clone_fresh_repo() {
    # The checkout is refreshed by design. Re-cloning gives this run a clean
    # wrapper repo before we pin it to the published release tag and restore the
    # source archive.
    explain "start from a newly cloned macOS wrapper repo so this build begins from a known place"
    info "Cloning refreshed repo from ${REPO_URL}"
    info "Clone destination: ${REPO_DIR}"

    [[ ! -e "${REPO_DIR}" ]] || error "Stopping before clone: destination already exists: ${REPO_DIR}"
    git clone "${REPO_URL}" "${REPO_DIR}"

    is_git_worktree "${REPO_DIR}" || error "Fresh clone did not produce a git worktree at ${REPO_DIR}"
    success "Refreshed repo clone complete"
}

guard_build_delete_target() {
    local target="${BUILD_DIR}"
    local expected="${SCRIPT_DIR}/ungoogled-chromium-macos/build"
    local target_basename

    # The full repo refresh should already remove generated state. This guard is
    # still useful because build/ can be recreated after checkout alignment, and
    # the cleanup function should remain safe if called independently later.
    [[ -n "${target}" ]] || error "Stopping before build cleanup: target path is empty."
    [[ "${target}" = /* ]] || error "Stopping before build cleanup: target path is not absolute: ${target}"
    [[ "${target}" != "/" ]] || error "Stopping before build cleanup: target path is /."
    [[ "${target}" != "${SCRIPT_DIR}" ]] || error "Stopping before build cleanup: target path is SCRIPT_DIR: ${target}"
    [[ "${target}" != "${REPO_DIR}" ]] || error "Stopping before build cleanup: target path is REPO_DIR: ${target}"
    [[ "${target}" == "${expected}" ]] || error "Stopping before build cleanup: expected ${expected}, got ${target}"

    target_basename="$(basename "${target}")"
    [[ "${target_basename}" == "build" ]] || error "Stopping before build cleanup: unexpected basename ${target_basename}"
}

load_config() {
    # forge.conf is where this wrapper keeps local build choices: target
    # architecture and optional signing/notarization inputs. Source it once,
    # normalize the architecture names, then export signing variables for the
    # upstream helper script if signing is configured.
    # shellcheck source=/dev/null
    source "${CONF_FILE}"

    ARCH="${ARCH:-arm64}"

    export MACOS_CERTIFICATE_NAME="${MACOS_CERTIFICATE_NAME:-}"
    export PROD_MACOS_NOTARIZATION_APPLE_ID="${PROD_MACOS_NOTARIZATION_APPLE_ID:-}"
    export PROD_MACOS_NOTARIZATION_TEAM_ID="${PROD_MACOS_NOTARIZATION_TEAM_ID:-}"
    export PROD_MACOS_NOTARIZATION_PWD="${PROD_MACOS_NOTARIZATION_PWD:-}"

    case "${ARCH}" in
        arm64)
            ARCH_GN="arm64"
            ARCH_RESOURCE="arm64"
            ;;
        x64|x86_64)
            ARCH_GN="x64"
            ARCH_RESOURCE="x86_64"
            ;;
        *)
            error "Unsupported ARCH='${ARCH}' in ${CONF_FILE}. Use 'arm64' or 'x64'."
            ;;
    esac
}

validate_local_version_consistency() {
    section "validating local version consistency"
    explain "stop before any wipe or build if the fork's declared version and the local checkout disagree"

    # Three places state a Chromium version for this workspace:
    #   - forge.conf VERSION       (this fork's declared build target)
    #   - version.txt              (the version marker file beside the script)
    #   - ungoogled-chromium/chromium_version.txt (the version present on disk)
    # The first two should always agree; if they do not, the workspace is
    # internally inconsistent. If the local checkout exists and disagrees with
    # the declared version, the workspace is out of sync with what the script
    # is about to build. Catching either case here keeps the wipe-and-rebuild
    # honest before any destructive or expensive work begins.
    local conf_version="${VERSION:-}"
    local marker_version=""
    local checkout_version=""
    local checkout_version_file="${MAIN_REPO}/chromium_version.txt"

    [[ -n "${conf_version}" ]] || error "forge.conf is missing VERSION. Set VERSION=\"...\" in ${CONF_FILE}."

    if [[ -s "${VERSION_FILE}" ]]; then
        marker_version="$(tr -d '[:space:]' < "${VERSION_FILE}")"
    fi
    [[ -n "${marker_version}" ]] || error "version.txt is empty or missing. Set the expected Chromium version in ${VERSION_FILE}."

    info "Expected (forge.conf VERSION): ${conf_version}"
    info "Expected (version.txt):        ${marker_version}"

    if [[ "${conf_version}" != "${marker_version}" ]]; then
        error "local version declarations disagree.
  expected (forge.conf VERSION): ${conf_version}
    from ${CONF_FILE}
  expected (version.txt):        ${marker_version}
    from ${VERSION_FILE}
  Update one of these so both files state the same Chromium version, then run ./forge.sh again."
    fi

    if [[ -f "${checkout_version_file}" ]]; then
        checkout_version="$(tr -d '[:space:]' < "${checkout_version_file}")"
        info "Detected (local checkout):     ${checkout_version}"

        if [[ -n "${checkout_version}" && "${checkout_version}" != "${conf_version}" ]]; then
            error "local checkout version does not match this fork's declared version.
  expected: ${conf_version}
    from ${CONF_FILE} and ${VERSION_FILE}
  detected: ${checkout_version}
    from ${checkout_version_file}
  Update ${CONF_FILE} and ${VERSION_FILE} to match the checkout, or refresh the checkout to match the declared version, before running ./forge.sh again."
        fi
    else
        info "No local checkout version file at ${checkout_version_file}; nothing to compare against"
    fi

    success "Local version declarations are consistent"
}

check_for_update() {
    section "checking upstream for a newer release"
    explain "compare the latest published ungoogled-chromium-macos release against the last verified local build"

    # Remote: the same source the full build uses — the latest release tag from
    # the ungoogled-chromium-macos GitHub releases API. Pulled here via the
    # existing minimal helper (one curl + python tag_name extraction).
    #
    # Local: .forge-last-built-version, written at the end of a successful build.
    # That marker is the only file that proves verify_outputs passed; version.txt
    # only records what the most recent run intended to build, not what shipped.
    # If the marker does not exist yet (first --check on a fresh workspace, or
    # the last build predates this feature), fall back to version.txt with a
    # plain note that the comparison is at Chromium-version precision only.
    fetch_latest_release_metadata

    local local_tag=""
    local local_version=""
    local local_source=""
    local fallback_used=0

    if [[ -s "${LAST_BUILT_VERSION_FILE}" ]]; then
        local_tag="$(tr -d '[:space:]' < "${LAST_BUILT_VERSION_FILE}")"
        local_source="${LAST_BUILT_VERSION_FILE}"
        local_version="$(extract_chromium_version_from_tag "${local_tag}")"
        if [[ -z "${local_version}" ]]; then
            # Marker held a bare Chromium version (no -N.N suffix); accept it as
            # version-only and drop the tag so we use the version comparison path.
            local_version="${local_tag}"
            local_tag=""
        fi
    elif [[ -s "${VERSION_FILE}" ]]; then
        local_version="$(tr -d '[:space:]' < "${VERSION_FILE}")"
        local_source="${VERSION_FILE}"
        fallback_used=1
    fi

    info ""
    info "Latest remote tag:     ${LATEST_TAG}"
    info "Latest remote version: ${LATEST_VERSION}"
    if [[ -n "${local_tag}" ]]; then
        info "Last built tag:        ${local_tag}"
    fi
    info "Last built version:    ${local_version:-<unknown>}"
    info "Local source:          ${local_source:-<none>}"
    if (( fallback_used )); then
        info "Note: no ${LAST_BUILT_VERSION_FILE} yet; falling back to version.txt."
        info "      Comparison is at Chromium-version precision; wrapper revisions"
        info "      (e.g., -1.1 vs -1.2) cannot be distinguished until the next"
        info "      successful ./forge.sh writes the marker."
    fi
    info ""

    if [[ -z "${local_version}" ]]; then
        info "Status: no local build recorded yet. Run ./forge.sh to produce one."
        return
    fi

    # Prefer tag-precise comparison when both sides have a tag. Otherwise the
    # marker is missing and we fall back to Chromium-version comparison from
    # version.txt, which is coarser but still useful.
    if [[ -n "${local_tag}" ]]; then
        if [[ "${local_tag}" == "${LATEST_TAG}" ]]; then
            success "Status: current. Local build matches latest release ${LATEST_TAG}."
        else
            info "Status: update available. Upstream ${LATEST_TAG} differs from local ${local_tag}."
            info "Run ./forge.sh to rebuild against the latest release."
        fi
    else
        if [[ "${local_version}" == "${LATEST_VERSION}" ]]; then
            success "Status: current at Chromium ${LATEST_VERSION} (version-only match)."
        else
            info "Status: update available. Upstream Chromium ${LATEST_VERSION} differs from local ${local_version}."
            info "Run ./forge.sh to rebuild against the latest release."
        fi
    fi
}

print_run_config() {
    section "configuration"
    explain "show the local build choices before network and build work begins"
    info "Ninja jobs: ${JOBS}"
    info "Repo refresh: clear and re-clone every run"
    info "Repo URL: ${REPO_URL}"
    info "Target architecture: ${ARCH_GN}"
    info "Download cache: ${DOWNLOAD_CACHE}"
    info "Source directory: ${SRC_DIR}"
}

extract_chromium_version_from_tag() {
    local tag_name="${1:-}"

    if [[ -z "${tag_name}" ]]; then
        echo ""
        return
    fi

    echo "${tag_name}" | sed -E 's/-[0-9]+\.[0-9]+$//'
}

fetch_latest_release_metadata() {
    section "discovering latest release"
    explain "ask GitHub which ungoogled-chromium-macos release should be rebuilt"

    # GitHub release metadata is the source of truth for "latest." The local
    # version files are updated from this value so the wrapper and upstream
    # checkout agree on the Chromium version before build inputs are restored.
    info "Fetching the latest ungoogled-chromium-macos release..."

    LATEST_TAG="$(
        curl -fsSL "${UNGOOGLED_RELEASES_API}" | \
        python3 -c "import json, sys; print(json.load(sys.stdin).get('tag_name', ''))"
    )"

    [[ -n "${LATEST_TAG}" ]] || error "Failed to read the latest release tag from ${UNGOOGLED_RELEASES_API}"

    LATEST_VERSION="$(extract_chromium_version_from_tag "${LATEST_TAG}")"
    [[ -n "${LATEST_VERSION}" ]] || error "Failed to extract a Chromium version from release tag '${LATEST_TAG}'"

    info "Latest release tag: ${LATEST_TAG}"
    info "Chromium version: ${LATEST_VERSION}"
}

ensure_release_tag_exists() {
    section "fetching release tags"
    explain "make the discovered release tag available in the fresh clone before checkout"

    # A fresh clone may not have every tag locally. Fetch tags explicitly, then
    # require the release tag we discovered from GitHub to exist before checkout.
    info "Fetching repo tags..."
    git -C "${REPO_DIR}" fetch --tags --prune

    git -C "${REPO_DIR}" rev-parse -q --verify "refs/tags/${LATEST_TAG}" >/dev/null || \
        error "Release tag '${LATEST_TAG}' was not found in ${REPO_DIR} after fetching tags."

    success "Verified release tag ${LATEST_TAG}"
}

update_version_markers() {
    section "updating local version markers"
    explain "record the Chromium version beside the script so the workspace documents this run"

    # Keep the local wrapper metadata synchronized with the release being built.
    # These authored files live beside the script, so updating them keeps the
    # workspace recipe in sync with the release this run targets.
    if grep -q '^VERSION=' "${CONF_FILE}"; then
        sed -i.bak "s/^VERSION=.*/VERSION=\"${LATEST_VERSION}\"/" "${CONF_FILE}"
        rm -f "${CONF_FILE}.bak"
        info "Updated ${CONF_FILE} VERSION=\"${LATEST_VERSION}\""
    else
        printf '\nVERSION="%s"\n' "${LATEST_VERSION}" >> "${CONF_FILE}"
        info "Added VERSION=\"${LATEST_VERSION}\" to ${CONF_FILE}"
    fi

    printf '%s\n' "${LATEST_VERSION}" > "${VERSION_FILE}"
    info "Updated ${VERSION_FILE}"

    # shellcheck disable=SC2034 # Keep the sourced config variable in sync for this run.
    VERSION="${LATEST_VERSION}"
}

align_repo_to_latest_release() {
    section "pinning fresh checkout"
    explain "detach the checkout at the published release tag and sync its submodule to the matching patch set"

    # Always build the published release tag, detached. Branch state is not part
    # of this workflow; the script is a release rebuilder, not a local branch
    # editing tool.
    info "Checking out ${LATEST_TAG}"
    git -C "${REPO_DIR}" checkout --detach "${LATEST_TAG}"

    # The ungoogled-chromium submodule contains the common patch set, pruning
    # lists, flags, and utilities. It must match the macOS release tag.
    git -C "${REPO_DIR}" submodule update --init --recursive

    success "Repo checkout aligned to ${LATEST_TAG}"
}

validate_post_checkout_layout() {
    section "validating pinned checkout"
    explain "stop early if the pinned release does not contain the files required for patching and flag generation"

    # These files are the contract between the macOS wrapper and the shared
    # ungoogled-chromium repo. If any are absent after checkout/submodule init,
    # building would fail later with a worse error, so stop here.
    require_dir "${MAIN_REPO}"
    require_file "${MAIN_REPO}/chromium_version.txt"
    require_file "${FLAGS_BASE}"
    require_file "${MAIN_REPO}/pruning.list"
    require_file "${MAIN_REPO}/domain_regex.list"
    require_file "${MAIN_REPO}/domain_substitution.list"
    require_file "${MAIN_REPO}/utils/prune_binaries.py"
    require_file "${MAIN_REPO}/utils/patches.py"
    require_file "${MAIN_REPO}/utils/domain_substitution.py"

    if [[ -n "${MACOS_CERTIFICATE_NAME}" ]]; then
        require_executable "${SIGN_SCRIPT}"
    fi

    local repo_version
    repo_version="$(<"${MAIN_REPO}/chromium_version.txt")"

    info "Repo chromium_version.txt: ${repo_version}"

    if [[ "${repo_version}" != "${LATEST_VERSION}" ]]; then
        error "Repo Chromium version '${repo_version}' does not match latest release version '${LATEST_VERSION}'."
    fi
}

delete_build_state() {
    section "clearing generated state"
    explain "remove generated build output so earlier files cannot shape the next run"

    # The repo itself was freshly cloned, but build/ is still treated as
    # generated state and explicitly removed after checkout alignment. This
    # keeps the build phase independent of partial retrievals, interrupted runs,
    # or generated files that appeared after the clone.
    info "Clearing ${BUILD_DIR}"

    if [[ -d "${BUILD_DIR}" ]]; then
        guard_build_delete_target

        local attempt
        for attempt in 1 2 3; do
            if rm -rf "${BUILD_DIR}" 2>/dev/null; then
                break
            fi

            warn "Build directory cleanup needed another pass on attempt ${attempt}; retrying."

            if [[ -d "${BUILD_DIR}" ]]; then
                find "${BUILD_DIR}" -name ".DS_Store" -delete 2>/dev/null || true
                find "${BUILD_DIR}" -depth -type d -empty -delete 2>/dev/null || true
            fi

            sleep 1
        done

        if [[ -e "${BUILD_DIR}" ]]; then
            find "${BUILD_DIR}" -name ".DS_Store" -delete 2>/dev/null || true
            find "${BUILD_DIR}" -depth -type d -empty -delete 2>/dev/null || true
        fi
    fi

    if [[ -e "${BUILD_DIR}" ]]; then
        warn "Remaining build tree after cleanup:"
        report_tree_sample "${BUILD_DIR}"
        error "Could not fully clear ${BUILD_DIR}. Close any Finder windows or other processes touching that tree and run ./forge.sh again."
    fi

    # Python helper scripts are used heavily during resource retrieval and patch
    # application. Bytecode caches are generated crumbs, so remove them before
    # continuing to keep the refreshed checkout easy to inspect.
    find "${REPO_DIR}" -name "*.pyc" -delete 2>/dev/null || true
    find "${REPO_DIR}" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true

    success "Generated workflow state cleared"
}

retrieve_sources_and_resources() {
    section "restoring source archive and shared resources"
    explain "download the known Chromium source archive instead of using the heavier gclient clone path"

    # Use the upstream helper's download mode (-d). Without -d, the helper takes
    # the git/gclient clone path, which has many more moving pieces for this
    # workflow and has broken before on Chromium DEPS/CIPD schema drift. The
    # archive path is the steady path: fetch the known Chromium release archive,
    # unpack it, then layer the macOS-specific shared resources on top.
    mkdir -p "${BUILD_DIR}"
    mkdir -p "${DOWNLOAD_CACHE}"
    mkdir -p "${SRC_DIR}"

    cd "${REPO_DIR}"

    info "Retrieving Chromium source archive and shared resources for ${ARCH_GN}"
    "${RETRIEVE_SCRIPT}" -d -g "${ARCH_RESOURCE}"

    require_dir "${SRC_DIR}"
    require_dir "${DOWNLOAD_CACHE}"
    require_file "${SRC_DIR}/DEPS"
    require_file "${SRC_DIR}/tools/gn/bootstrap/bootstrap.py"
    require_dir "${SRC_DIR}/build"
    require_dir "${SRC_DIR}/chrome"

    success "Sources and generic resources are ready"
}

series_has_entries() {
    local series_file="${1}"

    grep -Eq '^[[:space:]]*[^#[:space:]]' "${series_file}"
}

print_local_patch_notes() {
    local patch_path manifest_line _manifest_patch summary reason

    if ! series_has_entries "${LOCAL_PATCHES_SERIES}"; then
        info "No local custom patches listed yet; the local patch layer is ready when you are"
        return
    fi

    info "Local custom patch notes come from ${LOCAL_PATCHES_MANIFEST}"

    # Each non-comment entry in patches.local/series is a patch that will be
    # applied after upstream and macOS patches. The optional inline comments in
    # series are for quick scanning; manifest.tsv is the longer explanation that
    # the CLI prints here.
    while IFS= read -r patch_path; do
        info "Local patch: ${patch_path}"

        manifest_line="$(
            awk -F '\t' -v patch="${patch_path}" '
                $0 !~ /^[[:space:]]*(#|$)/ && $1 == patch {
                    print
                    found = 1
                    exit
                }
                END {
                    exit found ? 0 : 1
                }
            ' "${LOCAL_PATCHES_MANIFEST}" || true
        )"

        if [[ -z "${manifest_line}" ]]; then
            info "  why: no manifest note yet; add one so this patch can explain itself later"
            continue
        fi

        IFS=$'\t' read -r _manifest_patch summary reason <<< "${manifest_line}"
        info "  summary: ${summary:-<missing summary>}"
        info "  why: ${reason:-<missing reason>}"
    done < <(
        grep -E '^[[:space:]]*[^#[:space:]]' "${LOCAL_PATCHES_SERIES}" | \
            sed 's/[[:space:]]#.*$//' | \
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    )
}

apply_local_custom_patches() {
    # Local patches live beside this script and are intentionally applied last.
    # That makes them the workspace preference layer on top of upstream
    # ungoogled-chromium and macOS-specific compatibility patches.
    print_local_patch_notes

    if ! series_has_entries "${LOCAL_PATCHES_SERIES}"; then
        return
    fi

    python3 "${MAIN_REPO}/utils/patches.py" apply "${SRC_DIR}" "${LOCAL_PATCHES_DIR}"
}

apply_source_customizations() {
    section "applying source customizations"
    explain "turn upstream Chromium source into the ungoogled macOS source tree we actually want to build"

    # The upstream source archive is not the browser we want yet. This phase
    # turns raw Chromium into ungoogled-chromium for macOS by pruning unwanted
    # binaries, applying the shared patch stack, applying macOS-specific patches,
    # applying the local preference layer, and replacing configured Google
    # domains.
    info "Pruning binaries..."
    python3 "${MAIN_REPO}/utils/prune_binaries.py" "${SRC_DIR}" "${MAIN_REPO}/pruning.list"

    info "Applying upstream ungoogled-chromium patch stack..."
    python3 "${MAIN_REPO}/utils/patches.py" apply "${SRC_DIR}" "${MAIN_REPO}/patches"

    info "Applying macOS patch stack..."
    python3 "${MAIN_REPO}/utils/patches.py" apply "${SRC_DIR}" "${REPO_DIR}/patches"

    info "Applying local custom patch layer..."
    apply_local_custom_patches

    info "Applying domain substitution..."
    python3 "${MAIN_REPO}/utils/domain_substitution.py" apply \
        -r "${MAIN_REPO}/domain_regex.list" \
        -f "${MAIN_REPO}/domain_substitution.list" \
        "${SRC_DIR}"

    success "Source customizations applied"
}

write_args_gn() {
    section "generating args.gn"
    explain "combine upstream flags with local macOS flags, then force the configured target CPU"

    # args.gn is generated, not hand-edited. Start from upstream flags, layer the
    # local macOS flags, and then write target_cpu last so the configured ARCH in
    # forge.conf wins even if either flags file already contains a target_cpu.
    mkdir -p "${SRC_DIR}/out/Default"

    {
        sed '/^[[:space:]]*target_cpu[[:space:]]*=.*/d' "${FLAGS_BASE}"
        printf '\n'
        sed '/^[[:space:]]*target_cpu[[:space:]]*=.*/d' "${FLAGS_MACOS}"
        printf '\n'
        printf 'target_cpu = "%s"\n' "${ARCH_GN}"
    } > "${FLAGS_OUTPUT}"

    info "Wrote ${FLAGS_OUTPUT}"
    while IFS= read -r line; do
        info "  ${line}"
    done < "${FLAGS_OUTPUT}"
}

retrieve_platform_resources() {
    section "restoring platform resources"
    explain "restore the macOS toolchain pieces GN and Ninja need before compilation starts"

    # Toolchains are large, generated dependencies. Restore them after patching
    # and args generation so the source tree has the expected macOS LLVM, Rust,
    # and Node pieces before GN and Ninja inspect it.
    cd "${REPO_DIR}"

    info "Retrieving platform-specific resources for ${ARCH_GN}"
    "${RETRIEVE_SCRIPT}" -d -p "${ARCH_RESOURCE}"

    require_dir "${SRC_DIR}/third_party/llvm-build/Release+Asserts"
    require_dir "${SRC_DIR}/third_party/rust-toolchain"
    require_executable "${SRC_DIR}/third_party/llvm-build/Release+Asserts/bin/clang"
    require_executable "${SRC_DIR}/third_party/llvm-build/Release+Asserts/bin/llvm-config"
    require_executable "${SRC_DIR}/third_party/rust-toolchain/bin/cargo"
    require_executable "${SRC_DIR}/third_party/rust-toolchain/bin/rustc"

    success "Platform-specific resources are ready"
}

build_from_scratch() {
    section "rebuilding"
    explain "bootstrap the build tools, generate the build graph, then let Ninja compile and link"

    # Chromium's build has several generated layers. Bootstrap GN first, build
    # bindgen for Rust/C++ interop, ask GN to materialize the Ninja build graph,
    # then let Ninja perform the actual compile and link.
    cd "${SRC_DIR}"

    info "Bootstrapping GN..."
    ./tools/gn/bootstrap/bootstrap.py -o out/Default/gn --skip-generate-buildfiles

    info "Building bindgen..."
    ./tools/rust/build_bindgen.py --skip-test

    info "Generating build files..."
    ./out/Default/gn gen out/Default --fail-on-unused-args

    info "Running ninja with ${JOBS} job(s)..."
    ninja -j "${JOBS}" -C out/Default chrome chromedriver

    info ""
    info "Output:"
    info "  App: ${SRC_DIR}/out/Default/Chromium.app"
    info "  ChromeDriver: ${SRC_DIR}/out/Default/chromedriver"

    if [[ -n "${MACOS_CERTIFICATE_NAME}" ]]; then
        # Signing is intentionally config-driven. If the local forge.conf does
        # not provide a certificate name, produce unsigned build artifacts
        # instead of guessing at developer identity.
        info "Code signing and packaging..."
        "${SIGN_SCRIPT}"
    else
        info "Skipping code signing (MACOS_CERTIFICATE_NAME not set)"
    fi

    success "Build completed"
}

verify_outputs() {
    section "verifying"
    explain "check that the build produced the app bundle and chromedriver promised by this workflow"

    # Treat expected artifacts as part of the contract. Ninja can fail loudly,
    # but an explicit artifact check gives the final log a clear "yes, the
    # deliverables exist" moment and catches any future target-name drift.
    require_dir "${SRC_DIR}/out/Default/Chromium.app"
    require_executable "${SRC_DIR}/out/Default/chromedriver"

    success "Verified Chromium.app and chromedriver"
}

record_built_version() {
    # Stamp the release tag whose artifacts just passed verify_outputs. This is
    # the marker ./forge.sh --check reads to answer "is my local build current?"
    # The full tag is stored (not just the Chromium version) so wrapper-only
    # revisions like -1.1 -> -1.2 register as updates even when Chromium itself
    # has not moved.
    if [[ -z "${LATEST_TAG}" ]]; then
        warn "Skipping built-version marker write: LATEST_TAG is empty"
        return
    fi

    printf '%s\n' "${LATEST_TAG}" > "${LAST_BUILT_VERSION_FILE}"
    info "Recorded built release in ${LAST_BUILT_VERSION_FILE}: ${LATEST_TAG}"
}

main() {
    parse_args "$@"
    log_init
    print_shell_telemetry

    section "clean"
    validate_host_layout
    load_config
    validate_local_version_consistency

    # --check is a read-only preflight + upstream version probe: validate the
    # workbench, confirm local version files agree, then hit the GitHub releases
    # API to compare the latest published tag against the last verified local
    # build. No refresh, no checkout work, no build.
    if [[ "${CHECK_ONLY}" == "1" ]]; then
        check_for_update
        section "done"
        success "Forge check complete."
        exit 0
    fi

    print_run_config

    section "refreshing repo checkout"
    info "Refreshing ${REPO_DIR} from upstream"
    safe_remove_repo_dir
    clone_fresh_repo

    section "restore dependencies"
    validate_repo_layout
    fetch_latest_release_metadata
    ensure_release_tag_exists
    update_version_markers
    align_repo_to_latest_release
    validate_post_checkout_layout
    delete_build_state
    retrieve_sources_and_resources
    apply_source_customizations

    section "generate"
    write_args_gn
    retrieve_platform_resources

    section "build"
    build_from_scratch
    verify_outputs
    record_built_version

    section "done"
    success "Full rebuild complete for ${LATEST_TAG}"
}

main "$@"
