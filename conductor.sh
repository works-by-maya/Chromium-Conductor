#!/usr/bin/env bash
#
# conductor.sh - build script for Chromium Conductor,
# a lean, Apple silicon-optimized build of ungoogled-chromium-macos
# with native, in-app Core Audio routing.
#
#
# The details:
#
# Chromium Conductor starts with ungoogled-chromium-macos, pulled straight
# from the upstream GitHub repository:
#
#   https://github.com/ungoogled-software/ungoogled-chromium-macos
#
# Afterward, local patches are added:
#
# Core Audio routing:
#   Each tab can be routed to the audio output device of your choice:
#   display speakers, an external DAC, computer speakers, etc.
#
# Lean Apple silicon build profile:
#   Built for Apple silicon with my preferred optimized build settings.
#
# The whole point is simple:
# Keep Chromium fast, lean, and in control of where audio goes.
#
#
# How to run it:
#
# ./conductor.sh
#   Delete the generated checkout, and start fresh from upstream.
#
# ./conductor.sh --check
#   See if a newer upstream release exists.
#
# ./conductor.sh --verify-only
#   Report source and build state. Delete nothing. Build nothing.
#
# ./conductor.sh --clean
#   Remove the generated checkout. Keep logs and authored files. Build nothing.
#
# ./conductor.sh --update-build
#   Time saver: Refresh what's changed, reapply patches, and rebuild.
#
# ./conductor.sh --help
#   Show this information.
#
#
# What matters:
#
# These files are the project:
#
#   conductor.sh
#   conductor.conf
#   version.txt
#   flags.macos.gn
#   patches.local/
#
# If these files change, Chromium Conductor changes.
#
# What can be recreated:
#
# These are generated or downloaded:
#
#   ungoogled-chromium-macos/
#   ungoogled-chromium-macos/build/src/
#   out/
#
# If they disappear, conductor.sh will recreate them.
#
#
# How rebuilds work:
#
# Full rebuilds start from a fresh upstream release.
#
# update-build keeps what is safe to keep, updates what needs refreshing,
# reapplies patches, and rebuilds.
#
# Do not patch over an already-patched tree.
# Refresh generated source first, then apply patches cleanly.
#
# How patches work:
#
# Upstream patches make Chromium less Google-y.
#
# macOS patches make Chromium build correctly on macOS.
#
# patches.local/ is where Chromium Conductor actually lives.
#
# Safety boundary:
#
# This script only cleans up things it owns.
#
# It should never touch your home folder, mounted drives, SSH keys,
# credentials, or anything else outside this project.
#
# The path checks exist to keep it that way.
#
set -euo pipefail

# Make unmatched globs behave like bash when running under zsh.
if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt NONOMATCH
fi

# Stamp the wall-clock start of this invocation as early as possible, so the
# elapsed-time line at the end reflects the whole run (preflight included), not
# just the compile. A Chromium build is a long sit; reporting how long it
# actually took is a small courtesy to whoever started it and walked away.
CONDUCTOR_START_EPOCH="$(date +%s)"

SCRIPT_SELF="$0"
if [[ -n "${BASH_VERSION:-}" ]]; then
    SCRIPT_SELF="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
    # shellcheck disable=SC2296 # zsh-only prompt expansion for the script path.
    SCRIPT_SELF="${(%):-%N}"
fi

SCRIPT_DIR="$(cd "$(dirname -- "${SCRIPT_SELF}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/conductor.conf"
LOG_DIR="${SCRIPT_DIR}/out/logs"
VERSION_FILE="${SCRIPT_DIR}/version.txt"
LAST_BUILT_VERSION_FILE="${SCRIPT_DIR}/.conductor-last-built-version"
# This build script was formerly named forge.sh. Earlier runs recorded the
# built release under the .forge- name; we read it forward so "is my build
# current?" survives the rename. See migrate_legacy_state.
LEGACY_LAST_BUILT_VERSION_FILE="${SCRIPT_DIR}/.forge-last-built-version"

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

UPDATE_BUILD_STASH_DIR="${BUILD_DIR}/.conductor-update-build-stash"
UPDATE_OUT_STASH="${UPDATE_BUILD_STASH_DIR}/out"
SOURCE_STATE_FILE="${BUILD_DIR}/.conductor-source-state"
# Legacy (pre-rename) source-state marker. It lives inside the generated build
# tree, so we never write or migrate it; verify-only only reads it as a
# fallback when the new marker is absent.
LEGACY_SOURCE_STATE_FILE="${BUILD_DIR}/.forge-source-state"

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
MODE="full"

log_init() {
    mkdir -p "${LOG_DIR}"
    LOG_FILE="${LOG_DIR}/conductor_$(date +%Y%m%d_%H%M%S).log"

    # Keep the screen readable, and keep a log for later.
    # Chromium builds take a while. Memory should not have to do paperwork.
    if ! exec > >(tee -a "${LOG_FILE}") 2>&1; then
        exec >> "${LOG_FILE}" 2>&1
    fi

    echo "[conductor] started: $(date)"
    echo "[conductor] log: ${LOG_FILE}"
}

section() {
    echo ""
    echo "[conductor] $*"
}

info() {
    echo "[conductor] $*"
}

explain() {
    echo "[conductor] why: $*"
}

warn() {
    echo "[conductor] warning: $*" >&2
}

error() {
    echo "[conductor] error: $*" >&2
    exit 1
}

success() {
    echo "[conductor] $*"
}

format_elapsed_since_start() {
    # Render this invocation's runtime as a compact, human value:
    #   under a minute      -> "42s"
    #   under an hour       -> "12m 08s"
    #   an hour or more     -> "3h 40m 03s"
    # The leading unit is unpadded; smaller units are zero-padded to two digits
    # so the tail always lines up cleanly.
    local now elapsed h m s
    now="$(date +%s)"
    elapsed=$(( now - CONDUCTOR_START_EPOCH ))

    # If the wall clock stepped backwards mid-run (e.g. an NTP correction),
    # report zero rather than a confusing negative duration.
    if (( elapsed < 0 )); then
        elapsed=0
    fi

    h=$(( elapsed / 3600 ))
    m=$(( (elapsed % 3600) / 60 ))
    s=$(( elapsed % 60 ))

    if (( h > 0 )); then
        printf '%dh %02dm %02ds' "${h}" "${m}" "${s}"
    elif (( m > 0 )); then
        printf '%dm %02ds' "${m}" "${s}"
    else
        printf '%ds' "${s}"
    fi
}

mode_description() {
    case "${MODE}" in
        full)
            echo "full clean rebuild"
            ;;
        check)
            echo "version check only"
            ;;
        verify-only)
            echo "verify-only: report source/build state, change nothing"
            ;;
        clean)
            echo "clean: remove generated checkout, keep logs and authored files"
            ;;
        update-build)
            echo "update-build: refresh, patch, rebuild"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

print_mode() {
    section "mode"
    info "Mode: $(mode_description)"
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
Chromium Conductor

conductor.sh builds Chromium Conductor:
a lean, Apple silicon-optimized build of ungoogled-chromium-macos
with native, in-app Core Audio routing.

How to run it:

./conductor.sh
  Delete the generated checkout, and start fresh from upstream.

./conductor.sh --check
  See if a newer upstream release exists.
  No deleting. No patching. No building.

./conductor.sh --verify-only
  Report whether a Chromium from this tree is running, whether the source
  checkout is present and looks complete, and whether build output exists.
  No deleting. No patching. No building.

./conductor.sh --clean
  Remove the generated checkout (clone, build/, source, download cache).
  Keeps logs and authored files. Refuses if a Chromium from this tree is
  running, and asks for confirmation first. No patching. No building.

./conductor.sh --update-build
  Time saver: Refresh what's changed, reapply patches, and rebuild.

./conductor.sh --help
  Show this information.

These files are the project:

  conductor.sh
  conductor.conf
  version.txt
  flags.macos.gn
  patches.local/

If these files change, Chromium Conductor changes.

These are generated or downloaded:

  ungoogled-chromium-macos/
  ungoogled-chromium-macos/build/src/
  out/

If they disappear, conductor.sh will recreate them.

How Chromium Conductor is built:

  Upstream patches make Chromium less Google-y.
  macOS patches make Chromium build correctly on macOS.
  patches.local/ is where Chromium Conductor actually lives.

Safety boundary:

  This script only cleans up things it owns.
  It should never touch your home folder, mounted drives,
  SSH keys, credentials, or anything else outside this project.

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

    # Mode selection happens before logging or cleanup. Unknown options stop
    # here so a typo cannot accidentally start a destructive full rebuild.
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            -h|--help)
                show_help_and_exit
                ;;
            --check)
                [[ "${MODE}" == "full" ]] || {
                    echo "Only one mode can be selected." >&2
                    echo "Run ./conductor.sh --help for usage." >&2
                    exit 1
                }
                MODE="check"
                shift
                ;;
            --verify-only)
                [[ "${MODE}" == "full" ]] || {
                    echo "Only one mode can be selected." >&2
                    echo "Run ./conductor.sh --help for usage." >&2
                    exit 1
                }
                MODE="verify-only"
                shift
                ;;
            --clean)
                [[ "${MODE}" == "full" ]] || {
                    echo "Only one mode can be selected." >&2
                    echo "Run ./conductor.sh --help for usage." >&2
                    exit 1
                }
                MODE="clean"
                shift
                ;;
            --update-build)
                [[ "${MODE}" == "full" ]] || {
                    echo "Only one mode can be selected." >&2
                    echo "Run ./conductor.sh --help for usage." >&2
                    exit 1
                }
                MODE="update-build"
                shift
                ;;
            *)
                echo "Unknown option: ${1}" >&2
                echo "Run ./conductor.sh --help for usage." >&2
                exit 1
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

# ---------------------------------------------------------------------------
# Running-build detection
#
# The build emits Chromium.app and chromedriver under ${SRC_DIR}/out/Default,
# and that tree usually lives on an external volume. If a browser launched from
# there is still running when we delete the tree, the process keeps its open
# files in memory while its on-disk resources vanish underneath it: audio and
# already-loaded pages keep working, but normal browsing breaks, and the delete
# itself fails halfway with "Directory not empty". That is the ghost we refuse
# to create. Detect it, then stop before touching anything.
# ---------------------------------------------------------------------------
running_build_output_pids() {
    # Everything this build can launch lives under ${SRC_DIR}/out/Default, so a
    # process whose command line references that path is a browser or
    # chromedriver from this tree. We snapshot the process table first, then
    # match in memory, so neither ps nor grep can match its own command line.
    # grep -F is a literal match, so a path containing dots or other characters
    # can never be misread as a regular expression. argv strings persist even
    # after a binary is unlinked, so this also catches a half-deleted ghost from
    # an earlier interrupted run.
    local needle="${SRC_DIR}/out/Default"
    local snapshot
    snapshot="$(ps -A -ww -o pid= -o command=)"

    # grep exits 1 when nothing matches. Here that is the normal "nothing is
    # running" case, not a failure, so it is allowed to pass through.
    printf '%s\n' "${snapshot}" | grep -F -- "${needle}" | awk '{print $1}' || true
}

assert_no_running_build_output() {
    local context="${1}"
    local pids
    pids="$(running_build_output_pids)"

    if [[ -z "${pids}" ]]; then
        return 0
    fi

    warn "Refusing to ${context}."
    warn "A Chromium built from this tree is still running:"

    local pid
    while IFS= read -r pid; do
        [[ -n "${pid}" ]] || continue
        # Best-effort identity for each offending process. If it exits between
        # detection and here, ps simply prints nothing for that pid.
        ps -o pid=,comm= -p "${pid}" 2>/dev/null | sed 's/^/[conductor]   /' >&2 || true
    done <<< "${pids}"

    warn "Build output path: ${SRC_DIR}/out/Default"
    warn "Quit that Chromium (and any chromedriver) launched from this tree, then run conductor.sh again."
    error "Stopping before deleting a running build. Nothing was changed."
}

validate_host_layout() {
    section "checking local files"
    explain "make sure the machine and project files are ready before anything changes"

    # Check tools and authored project files before touching generated state.
    # If something is missing, stop early and say so plainly.
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
    section "checking upstream checkout"
    explain "confirm the fresh checkout has the helper scripts this build needs"

    # After cloning, validate the exact upstream shape we depend on. This keeps
    # upstream layout changes near the top of the log instead of hiding them
    # halfway through source retrieval or patching.
    require_dir "${REPO_DIR}"
    require_executable "${RETRIEVE_SCRIPT}"

    is_git_worktree "${REPO_DIR}" || error "Expected a git checkout at ${REPO_DIR}"

    info "Upstream checkout: ${REPO_DIR}"
    info "Retrieve script: ${RETRIEVE_SCRIPT}"
    success "Upstream checkout is ready"
}

robust_remove_tree() {
    # Move-then-delete. On a Spotlight-indexed external volume, Finder / Desktop
    # Services can write .DS_Store into directories as rm empties them (even with
    # only the project root open in Finder, folder traversal / size / indexing
    # work can reach deep dirs), so the parent rmdir then fails "Directory not
    # empty" and a single rm -rf cannot finish.
    #
    # We:
    #   1) atomically rename the live path to a hidden, dot-prefixed sibling. The
    #      rename frees the live path instantly, and the dot prefix keeps Finder
    #      from listing or traversing the staged copy, so it stops dropping new
    #      .DS_Store into it.
    #   2) rm -rf the staged copy, sweeping .DS_Store between attempts in case
    #      indexing/Finder still races us.
    #   3) stop loudly if anything survives. rm failures are never hidden.
    #
    # Callers MUST run the path guards and the running-build guard first; this
    # re-checks the essential path invariants so it is safe if reused.
    local target="${1}" label="${2}" staging attempt rm_status

    [[ -n "${target}" ]]                 || error "Refusing to ${label}: empty target path."
    [[ "${target}" = /* ]]               || error "Refusing to ${label}: target not absolute: ${target}"
    [[ "${target}" != "/" ]]             || error "Refusing to ${label}: target is /."
    [[ "${target}" != "${SCRIPT_DIR}" ]] || error "Refusing to ${label}: target is SCRIPT_DIR: ${target}"
    [[ -d "${target}" ]]                 || error "Refusing to ${label}: target is not a directory: ${target}"

    # Unique, hidden sibling inside SCRIPT_DIR -> same volume -> atomic rename.
    staging="${SCRIPT_DIR}/.conductor-trash-$(basename "${target}")-$$-$(date +%Y%m%d_%H%M%S)"
    [[ ! -e "${staging}" ]] || error "Refusing to ${label}: staging path already exists: ${staging}"

    info "Staging for deletion: ${target}"
    info "             -> ${staging}"
    mv "${target}" "${staging}"
    [[ ! -e "${target}" ]] || error "Could not stage ${label}: live path still present after rename: ${target}"

    info "Deleting staged copy: ${staging}"
    for attempt in 1 2 3 4 5; do
        rm_status=0
        rm -rf "${staging}" || rm_status=$?
        [[ -e "${staging}" ]] || break

        warn "Staged cleanup needed another pass on attempt ${attempt} (rm exit ${rm_status}); sweeping .DS_Store and retrying."
        find "${staging}" -name '.DS_Store' -delete \
            || warn "Could not sweep all .DS_Store under ${staging}"
        sleep 1
    done

    if [[ -e "${staging}" ]]; then
        warn "Remaining after staged cleanup of ${label}:"
        report_tree_sample "${staging}"
        error "Could not fully delete ${staging} (staged from ${target}).
  The live path is already cleared, but this staged copy could not be removed.
  A Finder window or indexing on this external volume is most likely recreating
  .DS_Store files as fast as rm deletes them.
  Close any Finder windows under ${SCRIPT_DIR}, let indexing settle, then delete:
    ${staging}
  conductor.sh stopped rather than leave this hidden."
    fi

    success "Cleared (${label})"
}

safe_remove_repo_dir() {
    local target="${REPO_DIR}"
    local expected="${SCRIPT_DIR}/ungoogled-chromium-macos"
    local target_basename

    # Full rebuild may delete the generated checkout, but only this exact path.
    # If the project shape is not what we expect, stop before anything is deleted.
    [[ -n "${target}" ]] || error "Stopping before repo cleanup: target path is empty."
    [[ "${target}" = /* ]] || error "Stopping before repo cleanup: target path is not absolute: ${target}"
    [[ "${target}" != "/" ]] || error "Stopping before repo cleanup: target path is /."
    [[ "${target}" != "${SCRIPT_DIR}" ]] || error "Stopping before repo cleanup: target path is SCRIPT_DIR: ${target}"
    [[ "${target}" == "${expected}" ]] || error "Stopping before repo cleanup: expected ${expected}, got ${target}"

    target_basename="$(basename "${target}")"
    [[ "${target_basename}" == "ungoogled-chromium-macos" ]] || error "Stopping before repo cleanup: unexpected basename ${target_basename}"
    [[ ! -e "${target}" || -d "${target}" ]] || error "Stopping before repo cleanup: target exists but is not a directory: ${target}"

    if [[ ! -e "${target}" ]]; then
        info "No generated checkout to clear: ${target}"
        return
    fi

    # Never delete a tree a live browser is still running from.
    assert_no_running_build_output "delete the generated checkout"

    # Move-then-delete to survive .DS_Store recreation races on this external
    # volume (see robust_remove_tree).
    robust_remove_tree "${target}" "delete the generated checkout"

    [[ ! -e "${target}" ]] || error "Could not finish repo cleanup: ${target}"
    success "Generated checkout cleared: ${target}"
}

confirm_destructive() {
    # Gate an irreversible-feeling action behind an explicit yes. Automation can
    # set CONDUCTOR_ASSUME_YES=1 to opt in ahead of time; with no terminal and no
    # opt-in we refuse rather than guess, so a stray invocation cannot delete in
    # a context where nobody could answer.
    local action="${1}"

    # FORGE_ASSUME_YES is the pre-rename name. Honor it as a deprecated alias so
    # existing automation does not silently start prompting (and then fail under
    # no terminal) after the rename, but say plainly that it is deprecated.
    if [[ "${CONDUCTOR_ASSUME_YES:-0}" == "1" ]]; then
        info "CONDUCTOR_ASSUME_YES=1 set; proceeding with: ${action}"
        return 0
    fi
    if [[ "${FORGE_ASSUME_YES:-0}" == "1" ]]; then
        warn "FORGE_ASSUME_YES is deprecated; set CONDUCTOR_ASSUME_YES=1 instead."
        info "FORGE_ASSUME_YES=1 set; proceeding with: ${action}"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        error "Refusing to ${action} without confirmation: no terminal attached. Re-run interactively, or set CONDUCTOR_ASSUME_YES=1 if you are sure."
    fi

    # stdout is teed to the log, so prompt on the terminal directly and read the
    # answer from it too.
    local reply=""
    printf '[conductor] About to %s. Type "yes" to proceed: ' "${action}" > /dev/tty
    IFS= read -r reply < /dev/tty || reply=""

    if [[ "${reply}" == "yes" ]]; then
        return 0
    fi

    error "Not confirmed (got '${reply}'); nothing was changed."
}

clean_generated_state() {
    section "cleaning generated state"
    explain "remove only what conductor.sh owns and can recreate, and keep everything else"

    # --clean deletes the generated checkout (clone + build/ + build/src + the
    # download cache) — exactly what a full rebuild deletes first. It does NOT
    # touch authored project files (conductor.sh, conductor.conf, version.txt,
    # flags.macos.gn, patches.local/), the preserved logs under out/logs, or the
    # last-built-version marker. It reuses safe_remove_repo_dir, so the same path
    # guards and the running-browser guard apply.
    info "Will remove: ${REPO_DIR}"
    info "             (generated clone, build/, build/src, and download cache)"
    info "Will keep:   authored files, logs under ${LOG_DIR}, and ${LAST_BUILT_VERSION_FILE}"

    if [[ ! -e "${REPO_DIR}" ]]; then
        success "Nothing to clean: ${REPO_DIR} does not exist."
        return 0
    fi

    # Refuse early and clearly if a browser from this tree is still running, so
    # the confirmation prompt is never even shown for an unsafe delete.
    assert_no_running_build_output "clean the generated checkout"

    confirm_destructive "delete the generated checkout at ${REPO_DIR}"

    safe_remove_repo_dir

    success "Clean complete. Run ./conductor.sh to rebuild from upstream when ready."
}

clone_fresh_repo() {
    # Full rebuild starts with a fresh upstream wrapper checkout before source,
    # resources, and patches are restored.
    explain "clone upstream again so the rebuild starts from a known place"
    info "Cloning upstream repo from ${REPO_URL}"
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

guard_src_delete_target() {
    local target="${SRC_DIR}"
    local expected="${SCRIPT_DIR}/ungoogled-chromium-macos/build/src"
    local target_basename

    # --update-build may replace generated Chromium source, but only at this
    # exact path. Authored Chromium Conductor changes belong in patches.local/,
    # not as hand edits inside build/src.
    [[ -n "${target}" ]] || error "Stopping before source reset: target path is empty."
    [[ "${target}" = /* ]] || error "Stopping before source reset: target path is not absolute: ${target}"
    [[ "${target}" != "/" ]] || error "Stopping before source reset: target path is /."
    [[ "${target}" != "${SCRIPT_DIR}" ]] || error "Stopping before source reset: target path is SCRIPT_DIR: ${target}"
    [[ "${target}" != "${REPO_DIR}" ]] || error "Stopping before source reset: target path is REPO_DIR: ${target}"
    [[ "${target}" != "${BUILD_DIR}" ]] || error "Stopping before source reset: target path is BUILD_DIR: ${target}"
    [[ "${target}" == "${expected}" ]] || error "Stopping before source reset: expected ${expected}, got ${target}"

    target_basename="$(basename "${target}")"
    [[ "${target_basename}" == "src" ]] || error "Stopping before source reset: unexpected basename ${target_basename}"
}

ensure_git_tree_clean() {
    local repo_path="${1}"
    local label="${2}"
    local status_output

    is_git_worktree "${repo_path}" || error "Expected ${label} to be a git worktree: ${repo_path}"

    status_output="$(git -C "${repo_path}" status --porcelain --untracked-files=all)"
    if [[ -n "${status_output}" ]]; then
        warn "${label} has local changes:"
        printf '%s\n' "${status_output}" >&2
        error "Stopping before update-build changes ${label}. Inspect or preserve those changes, then rerun."
    fi

    success "${label} is clean"
}

validate_existing_update_checkout() {
    section "checking generated checkout"
    explain "confirm update-build has an existing checkout to reuse"

    if [[ ! -d "${REPO_DIR}" ]] || [[ ! -d "${MAIN_REPO}" ]] || [[ ! -d "${SRC_DIR}" ]]; then
        error "No existing checkout found. Run ./conductor.sh for a full clean rebuild first."
    fi

    require_executable "${RETRIEVE_SCRIPT}"
    is_git_worktree "${REPO_DIR}" || error "Expected a git checkout at ${REPO_DIR}"
    is_git_worktree "${MAIN_REPO}" || error "Expected a git checkout at ${MAIN_REPO}"
    require_file "${SRC_DIR}/DEPS"

    info "Generated checkout: ${REPO_DIR}"
    info "Ungoogled Chromium files: ${MAIN_REPO}"
    info "Generated Chromium source: ${SRC_DIR}"
    success "Generated checkout is present"
}

check_update_dirty_state() {
    section "checking for local changes"
    explain "stop before update-build if Git-tracked files need attention"

    ensure_git_tree_clean "${REPO_DIR}" "generated checkout"
    ensure_git_tree_clean "${MAIN_REPO}" "ungoogled Chromium files"

    if [[ -d "${SRC_DIR}" ]]; then
        info "Generated Chromium source is archive-unpacked, not its own Git checkout."
        info "update-build will refresh ${SRC_DIR} from the clean source archive before patching."
        info "Build cache at ${SRC_DIR}/out will be kept when possible."
    fi
}

load_config() {
    # conductor.conf is where this wrapper keeps local build choices: target
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
    section "checking local version files"
    explain "stop before deleting or building if the version files disagree"

    # conductor.conf and version.txt should agree. If generated Chromium files are
    # present, their Chromium version should agree too.
    local conf_version="${VERSION:-}"
    local marker_version=""
    local checkout_version=""
    local checkout_version_file="${MAIN_REPO}/chromium_version.txt"

    [[ -n "${conf_version}" ]] || error "conductor.conf is missing VERSION. Set VERSION=\"...\" in ${CONF_FILE}."

    if [[ -s "${VERSION_FILE}" ]]; then
        marker_version="$(tr -d '[:space:]' < "${VERSION_FILE}")"
    fi
    [[ -n "${marker_version}" ]] || error "version.txt is empty or missing. Set the expected Chromium version in ${VERSION_FILE}."

    info "Expected (conductor.conf VERSION): ${conf_version}"
    info "Expected (version.txt):        ${marker_version}"

    if [[ "${conf_version}" != "${marker_version}" ]]; then
        error "local version declarations disagree.
  expected (conductor.conf VERSION): ${conf_version}
    from ${CONF_FILE}
  expected (version.txt):        ${marker_version}
    from ${VERSION_FILE}
  Update one of these so both files state the same Chromium version, then run ./conductor.sh again."
    fi

    if [[ -f "${checkout_version_file}" ]]; then
        checkout_version="$(tr -d '[:space:]' < "${checkout_version_file}")"
        info "Detected (generated checkout): ${checkout_version}"

        if [[ -n "${checkout_version}" && "${checkout_version}" != "${conf_version}" ]]; then
            error "local checkout version does not match Chromium Conductor's declared version.
  expected: ${conf_version}
    from ${CONF_FILE} and ${VERSION_FILE}
  detected: ${checkout_version}
    from ${checkout_version_file}
  Update ${CONF_FILE} and ${VERSION_FILE} to match the checkout, or refresh the checkout to match the declared version, before running ./conductor.sh again."
        fi
    else
        info "No local checkout version file at ${checkout_version_file}; nothing to compare against"
    fi

    success "Local version declarations are consistent"
}

check_for_update() {
    section "checking upstream release"
    explain "read-only check: ask GitHub for latest release and compare it with the last successful build"

    # Remote means the latest upstream ungoogled-chromium-macos release.
    # Local means .conductor-last-built-version when it exists, because that file is
    # written only after a successful build. If there is no build marker yet,
    # fall back to version.txt; that can compare Chromium versions, but not
    # wrapper-only release suffixes like -1.1 vs -1.2.
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
    info "Upstream tag:        ${LATEST_TAG}"
    info "Upstream Chromium:   ${LATEST_VERSION}"
    if [[ -n "${local_tag}" ]]; then
        info "Last built tag:     ${local_tag}"
    fi
    info "Local Chromium:      ${local_version:-}"
    info "Compared from:       ${local_source:-}"
    if (( fallback_used )); then
        info "Note: no ${LAST_BUILT_VERSION_FILE} yet, so version.txt is being used."
        info "      This catches Chromium version changes, but not wrapper-only revisions."
        info "      The next successful build will write the precise marker."
    fi
    info ""

    if [[ -z "${local_version}" ]]; then
        info "Status: no local build recorded yet. Run ./conductor.sh to produce one."
        return
    fi

    # Prefer an exact release-tag comparison. If there is no built-tag marker
    # yet, use the Chromium version from version.txt as the best available clue.
    if [[ -n "${local_tag}" ]]; then
        if [[ "${local_tag}" == "${LATEST_TAG}" ]]; then
            success "Status: current: ${LATEST_TAG}"
        else
            info "Status: update available: upstream ${LATEST_TAG}, local ${local_tag}"
            info "Run ./conductor.sh to rebuild against the latest release."
        fi
    else
        if [[ "${local_version}" == "${LATEST_VERSION}" ]]; then
            success "Status: current at Chromium ${LATEST_VERSION} (version-only match)."
        else
            info "Status: update available. Upstream Chromium ${LATEST_VERSION} differs from local ${local_version}."
            info "Run ./conductor.sh to rebuild against the latest release."
        fi
    fi
}

print_run_config() {
    section "build choices"
    explain "show the local choices before network or build work starts"
    info "Ninja jobs: ${JOBS}"
    case "${MODE}" in
        full)
            info "Checkout: delete the generated checkout and start fresh"
            ;;
        update-build)
            info "Checkout: reuse what is safe, refresh generated source, keep out cache if possible"
            ;;
        *)
            info "Checkout: none"
            ;;
    esac
    info "Upstream repo: ${REPO_URL}"
    info "Target architecture: ${ARCH_GN}"
    info "Download cache: ${DOWNLOAD_CACHE}"
    info "Generated source: ${SRC_DIR}"
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
    # Discover the newest upstream ungoogled-chromium-macos release via the GitHub
    # REST API and populate LATEST_TAG / LATEST_VERSION.
    #
    # Failure DISPOSITION is caller-selected; the hardening is identical either way:
    #   (default) "fatal" -- abort with a friendly message. Used by --check.
    #   "soft"            -- return non-zero so the caller can fall back, e.g.
    #                        select_release_tag dropping to the declared version.
    #
    # Per 0940f5c, the transfer and the JSON parse are each validated before use,
    # so a transient outage (e.g. HTTP 504, empty body) becomes a clear message or
    # a clean non-zero return -- never a Python traceback or a crash under set -e.
    local disposition="${1:-fatal}"

    section "checking upstream release"
    explain "ask GitHub which upstream release is newest"
    info "Fetching the latest ungoogled-chromium-macos release..."

    # Collect any failure into one reason, then dispatch once at the end. The
    # globals are written only on full success, so a failure never leaves partial
    # state behind for a fallback caller to misread.
    local response="" parsed_tag="" parsed_version="" fail_reason=""

    if ! response="$(curl -fsSL "${UNGOOGLED_RELEASES_API}")"; then
        fail_reason="Could not reach GitHub to discover the latest release (curl failed)."
    elif [[ -z "${response}" ]]; then
        fail_reason="GitHub returned an empty latest-release response."
    fi

    if [[ -z "${fail_reason}" ]]; then
        # Parse in a separate, guarded step. Any non-JSON / unexpected shape exits
        # 2 (no traceback); the failed substitution is caught here, not by set -e.
        if ! parsed_tag="$(
            printf '%s' "${response}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)
print(data.get("tag_name", "") if isinstance(data, dict) else "")
' 2>/dev/null
        )"; then
            fail_reason="GitHub returned a response that was not valid JSON."
        elif [[ -z "${parsed_tag}" ]]; then
            fail_reason="GitHub's latest-release response contained no tag_name."
        fi
    fi

    if [[ -z "${fail_reason}" ]]; then
        parsed_version="$(extract_chromium_version_from_tag "${parsed_tag}")"
        [[ -n "${parsed_version}" ]] || fail_reason="Failed to extract a Chromium version from release tag '${parsed_tag}'."
    fi

    if [[ -n "${fail_reason}" ]]; then
        if [[ "${disposition}" == "soft" ]]; then
            warn "${fail_reason}"
            return 1
        fi
        error "${fail_reason}
  ${UNGOOGLED_RELEASES_API}
  This is often a transient GitHub outage (e.g. HTTP 5xx). Retry later, or set
  VERSION in ${CONF_FILE} (and ${VERSION_FILE}) to build a specific release."
    fi

    LATEST_TAG="${parsed_tag}"
    LATEST_VERSION="${parsed_version}"
    info "Latest release tag: ${LATEST_TAG}"
    info "Chromium version: ${LATEST_VERSION}"
    return 0
}

select_release_tag() {
    section "selecting release tag"
    explain "build the latest upstream macOS release; fall back to the declared version only if discovery is unavailable"

    # Make every upstream tag available locally first. This uses the git protocol
    # (the same path the clone just used), so it keeps working even when GitHub's
    # REST API is unavailable. A clone may not carry every tag, so fetch them.
    info "Fetching repo tags..."
    git -C "${REPO_DIR}" fetch --tags --prune

    # Latest-release-first. A fresh clone -- and every later run -- should track the
    # current upstream macOS release with no manual version editing, so ask GitHub
    # which release is newest (soft: a failure returns non-zero instead of aborting),
    # then confirm that tag is present in the tags we just fetched before trusting
    # it. The committed VERSION is a resilient FALLBACK, not a pin: it is consulted
    # only when discovery is unavailable, so a transient GitHub outage cannot block a
    # build -- and, per 0940f5c, cannot crash the script.
    local picked_latest=0
    if fetch_latest_release_metadata soft; then
        if git -C "${REPO_DIR}" rev-parse -q --verify "refs/tags/${LATEST_TAG}" >/dev/null; then
            info "Version source: upstream latest macOS release"
            info "  ${LATEST_TAG} (Chromium ${LATEST_VERSION})"
            picked_latest=1
        else
            warn "Upstream latest tag '${LATEST_TAG}' is not present in ${REPO_DIR} after fetching tags; falling back to the locally declared version."
        fi
    else
        warn "Upstream latest-release discovery is unavailable; falling back to the locally declared version."
    fi

    if (( ! picked_latest )); then
        # Fallback: resolve the declared version (conductor.conf VERSION, else
        # version.txt) to a concrete tag using local git tags only -- the resilient
        # 0940f5c path, no GitHub API.
        local declared_version="" version_source=""
        if [[ -n "${VERSION:-}" ]]; then
            declared_version="${VERSION}"
            version_source="${CONF_FILE}"
        elif [[ -s "${VERSION_FILE}" ]]; then
            declared_version="$(tr -d '[:space:]' < "${VERSION_FILE}")"
            version_source="${VERSION_FILE}"
        fi

        [[ -n "${declared_version}" ]] || error "Could not discover the latest upstream release, and no local VERSION is declared.
  Set VERSION in ${CONF_FILE} (and ${VERSION_FILE}) to a real ungoogled-chromium-macos
  release, or retry when GitHub is reachable."

        info "Version source: local declaration (fallback)"
        info "  ${declared_version} (from ${version_source})"
        resolve_release_tag_from_version "${declared_version}"
    fi

    success "Selected release tag: ${LATEST_TAG} (Chromium ${LATEST_VERSION})"
}

resolve_release_tag_from_version() {
    # Turn an explicit Chromium version (e.g. 149.0.7827.102) into a concrete
    # upstream release tag using local git tags only -- no GitHub API.
    #
    # Published release tags are "<chromium-version>-<wrapper-rev>" (e.g.
    # 149.0.7827.102-1.1), and that suffixed form is what GitHub's latest-release
    # returns and what the built-version marker records. Some versions ALSO carry
    # a bare "<version>" tag pointing at the same commit, but the suffixed tag is
    # the canonical release identity, so prefer it (highest wrapper rev). Fall
    # back to the bare tag only if no suffixed tag exists.
    local version="${1}" tags count
    LATEST_VERSION="${version}"

    tags="$(git -C "${REPO_DIR}" tag -l "${version}-*" | sort -V)"
    count="$(printf '%s' "${tags}" | grep -c . || true)"

    if [[ "${count}" -ge 1 ]]; then
        LATEST_TAG="$(printf '%s\n' "${tags}" | tail -n 1)"
        [[ "${count}" -eq 1 ]] || warn "Multiple tags match '${version}-*'; using the highest: ${LATEST_TAG}"
    elif git -C "${REPO_DIR}" rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
        LATEST_TAG="${version}"
    else
        error "No upstream release tag matches the declared version '${version}'.
  Looked for '${version}-*' and 'refs/tags/${version}' in ${REPO_DIR}.
  This fallback runs only when upstream latest-release discovery is unavailable.
  Retry when GitHub is reachable, or set VERSION in ${CONF_FILE} / ${VERSION_FILE}
  to a real ungoogled-chromium-macos release."
    fi

    info "Resolved release tag from local version: ${LATEST_TAG}"
}

update_version_markers() {
    section "updating local version files"
    explain "record the Chromium version this run is building"

    # conductor.conf and version.txt are authored project files. Keep them in sync
    # with the upstream release this run is about to build.
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
    section "pinning upstream checkout"
    explain "check out the published release and sync the matching ungoogled files"

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
    section "checking release files"
    explain "stop early if the pinned release is missing files needed for patches or flags"

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
    section "clearing generated build state"
    explain "remove generated build files from earlier runs"

    # build/ is generated state. Clear it during full rebuild so partial
    # downloads, interrupted runs, or stale build files cannot steer the next run.
    info "Clearing generated build state: ${BUILD_DIR}"

    if [[ -d "${BUILD_DIR}" ]]; then
        guard_build_delete_target
        # build/ holds out/Default/Chromium.app; do not pull it out from under
        # a running browser.
        assert_no_running_build_output "clear generated build state"

        # macOS Finder can recreate .DS_Store mid-delete and the external volume
        # can briefly hold directory entries, so a single rm may hit a transient
        # "Directory not empty". We retry a few times, sweeping .DS_Store between
        # attempts. We do NOT silence the outcome: the existence check after the
        # loop is the authoritative gate and stops loudly if anything remains.
        local attempt rm_status
        for attempt in 1 2 3; do
            rm_status=0
            rm -rf "${BUILD_DIR}" || rm_status=$?
            [[ -e "${BUILD_DIR}" ]] || break

            warn "Build directory cleanup needed another pass on attempt ${attempt} (rm exit ${rm_status}); retrying."
            # Best-effort .DS_Store sweep so the next rm can finish. If the sweep
            # itself fails, say so rather than hiding it; the real gate is below.
            find "${BUILD_DIR}" -name ".DS_Store" -delete \
                || warn "Could not sweep all .DS_Store files under ${BUILD_DIR}"
            sleep 1
        done
    fi

    if [[ -e "${BUILD_DIR}" ]]; then
        warn "Remaining build tree after cleanup:"
        report_tree_sample "${BUILD_DIR}"
        error "Could not fully clear ${BUILD_DIR}. Close any Finder windows or other processes touching that tree and run ./conductor.sh again."
    fi

    # Python bytecode caches are generated; remove them so a stale .pyc can never
    # shadow a helper script. A sweep failure is surfaced as a warning, not
    # silently dropped.
    find "${REPO_DIR}" -name "*.pyc" -delete \
        || warn "Could not remove all .pyc files under ${REPO_DIR}"
    find "${REPO_DIR}" -name "__pycache__" -type d -prune -exec rm -rf {} + \
        || warn "Could not remove all __pycache__ directories under ${REPO_DIR}"

    success "Generated build state cleared"
}

retrieve_sources_and_resources() {
    section "restoring Chromium source"
    explain "download the known Chromium source archive instead of using the heavier gclient path"

    # Use the upstream helper's download mode (-d). Without -d, the helper takes
    # the git/gclient clone path, which has many more moving pieces for this
    # workflow and has broken before on Chromium DEPS/CIPD schema drift. The
    # archive path is the steady path: fetch the known Chromium release archive,
    # unpack it, then layer the macOS-specific shared resources on top.
    mkdir -p "${BUILD_DIR}"
    mkdir -p "${DOWNLOAD_CACHE}"
    mkdir -p "${SRC_DIR}"

    cd "${REPO_DIR}"

    info "Retrieving Chromium source archive for ${ARCH_GN}"
    "${RETRIEVE_SCRIPT}" -d -g "${ARCH_RESOURCE}"

    require_dir "${SRC_DIR}"
    require_dir "${DOWNLOAD_CACHE}"
    require_file "${SRC_DIR}/DEPS"
    require_file "${SRC_DIR}/tools/gn/bootstrap/bootstrap.py"
    require_dir "${SRC_DIR}/build"
    require_dir "${SRC_DIR}/chrome"

    success "Chromium source is ready"
}

mark_source_state() {
    mkdir -p "${BUILD_DIR}"
    {
        printf 'mode=%s\n' "${MODE}"
        printf 'release_tag=%s\n' "${LATEST_TAG:-<unknown>}"
        printf 'chromium_version=%s\n' "${LATEST_VERSION:-<unknown>}"
        printf 'source_dir=%s\n' "${SRC_DIR}"
        printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${SOURCE_STATE_FILE}"
    info "Recorded generated source state in ${SOURCE_STATE_FILE}"
}

reset_generated_source_for_update() {
    section "refreshing generated source"
    explain "replace build/src before patching, while keeping build output cache when possible"

    require_dir "${BUILD_DIR}"
    require_dir "${SRC_DIR}"
    guard_src_delete_target
    # The source tree carries out/Default; refuse to replace it while a browser
    # built from it is still running.
    assert_no_running_build_output "refresh the generated source tree"

    if [[ -e "${UPDATE_BUILD_STASH_DIR}" ]]; then
        error "Stale update-build stash exists at ${UPDATE_BUILD_STASH_DIR}. Inspect it before rerunning update-build."
    fi

    local preserved_out=0
    if [[ -d "${SRC_DIR}/out" ]]; then
        mkdir -p "${UPDATE_BUILD_STASH_DIR}"
        info "Keeping build output cache: ${SRC_DIR}/out"
        mv "${SRC_DIR}/out" "${UPDATE_OUT_STASH}"
        preserved_out=1
    else
        info "No build output cache to keep at ${SRC_DIR}/out"
    fi

    info "Refreshing generated source tree: ${SRC_DIR}"
    rm -rf "${SRC_DIR}"
    mkdir -p "${SRC_DIR}"

    retrieve_sources_and_resources

    if (( preserved_out )); then
        [[ ! -e "${SRC_DIR}/out" ]] || error "Cannot restore preserved out cache because ${SRC_DIR}/out already exists."
        info "Restoring build output cache: ${SRC_DIR}/out"
        mv "${UPDATE_OUT_STASH}" "${SRC_DIR}/out"
        # The stash dir should be empty now. If it is not, something unexpected
        # was left behind, so surface it instead of silently ignoring it.
        rmdir "${UPDATE_BUILD_STASH_DIR}" \
            || warn "Update-build stash dir not empty after restoring out cache: ${UPDATE_BUILD_STASH_DIR}"
    fi

    success "Generated source refreshed from clean archive"
}

series_has_entries() {
    local series_file="${1}"

    grep -Eq '^[[:space:]]*[^#[:space:]]' "${series_file}"
}

print_local_patch_notes() {
    local patch_path manifest_line _manifest_patch summary reason

    if ! series_has_entries "${LOCAL_PATCHES_SERIES}"; then
        info "No patches.local entries yet"
        return
    fi

    info "patches.local notes: ${LOCAL_PATCHES_MANIFEST}"

    # patches.local/series is the local patch order. Inline comments are the
    # quick labels; manifest.tsv is the longer note printed here.
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
            info "  why: no manifest note yet"
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
    # patches.local/ is applied last on purpose. This is where Chromium Conductor
    # actually lives: Core Audio routing, tab menu work, and everything we've
    # added on top of ungoogled-chromium-macos.
    print_local_patch_notes

    if ! series_has_entries "${LOCAL_PATCHES_SERIES}"; then
        return
    fi

    python3 "${MAIN_REPO}/utils/patches.py" apply "${SRC_DIR}" "${LOCAL_PATCHES_DIR}"
}

assert_source_fully_patched() {
    # A clean patch run leaves no .rej files. Some patch tools exit 0 even when a
    # hunk is rejected (writing a .rej alongside the target), so verify this
    # explicitly rather than trusting exit status alone. A half-patched tree must
    # never reach the build: it would compile the wrong thing, or fail much later
    # in Ninja with a far more confusing error than this one.
    local rej_files rej_count
    rej_files="$(find "${SRC_DIR}" -type f -name '*.rej')"
    rej_count="$(printf '%s' "${rej_files}" | grep -c . || true)"

    if [[ "${rej_count}" != "0" ]]; then
        warn "Found ${rej_count} rejected patch hunk file(s) under ${SRC_DIR}:"
        printf '%s\n' "${rej_files}" | sed 's/^/[conductor]   rej: /' >&2
        error "Source is half-patched. Refusing to build. Refresh the failing patch(es), then rerun."
    fi

    info "No rejected patch hunks: the patch set applied cleanly"
}

apply_source_customizations() {
    section "preparing Chromium source"
    explain "apply ungoogled, macOS, and local patches before the build starts"

    # The source archive is raw Chromium. Prepare it in layers:
    # upstream ungoogled patches, macOS patches, patches.local/, then domain
    # substitution.
    info "Pruning binaries..."
    python3 "${MAIN_REPO}/utils/prune_binaries.py" "${SRC_DIR}" "${MAIN_REPO}/pruning.list"

    info "Applying upstream ungoogled patches..."
    python3 "${MAIN_REPO}/utils/patches.py" apply "${SRC_DIR}" "${MAIN_REPO}/patches"

    info "Applying macOS patches..."
    python3 "${MAIN_REPO}/utils/patches.py" apply "${SRC_DIR}" "${REPO_DIR}/patches"

    info "Applying patches.local..."
    apply_local_custom_patches

    info "Applying domain substitution..."
    python3 "${MAIN_REPO}/utils/domain_substitution.py" apply \
        -r "${MAIN_REPO}/domain_regex.list" \
        -f "${MAIN_REPO}/domain_substitution.list" \
        "${SRC_DIR}"

    # Completeness gate: never carry a half-patched tree into the build.
    assert_source_fully_patched

    success "Patches and cleanup applied"
}

write_args_gn() {
    section "writing args.gn"
    explain "combine upstream flags with local macOS flags, then set the target CPU"

    # args.gn is generated, not hand-edited. Start from upstream flags, layer the
    # local macOS flags, and then write target_cpu last so the configured ARCH in
    # conductor.conf wins even if either flags file already contains a target_cpu.
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
    section "restoring macOS build tools"
    explain "restore LLVM, Rust, and Node pieces before GN and Ninja inspect the tree"

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

    success "macOS build tools are ready"
}

build_from_scratch() {
    section "running GN and Ninja"
    explain "bootstrap build tools, generate the build graph, then compile Chromium.app"

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
        # Signing is intentionally config-driven. If the local conductor.conf does
        # not provide a certificate name, produce unsigned build artifacts
        # instead of guessing at developer identity.
        info "Code signing and packaging..."
        "${SIGN_SCRIPT}"
    else
        info "Skipping code signing (MACOS_CERTIFICATE_NAME not set)"
    fi

    success "Build finished"
}

verify_outputs() {
    section "checking build output"
    explain "make sure Chromium.app and chromedriver were produced"

    # Treat expected artifacts as part of the contract. Ninja can fail loudly,
    # but an explicit artifact check gives the final log a clear "yes, the
    # deliverables exist" moment and catches any future target-name drift.
    require_dir "${SRC_DIR}/out/Default/Chromium.app"
    require_executable "${SRC_DIR}/out/Default/chromedriver"

    success "Chromium.app and chromedriver are present"
}

record_built_version() {
    # Stamp the release tag whose artifacts just passed verify_outputs. This is
    # the marker ./conductor.sh --check reads to answer "is my local build current?"
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

verify_source_and_build_state() {
    section "verifying source and build state"
    explain "read-only report: no checkout changes, no patching, no building"

    # A running count of problems. Anything that would make a build unsafe or
    # impossible bumps it; the summary and the exit status reflect the total.
    local issues=0

    # 1. Is a browser from this tree running right now? A full or update-build
    #    run would refuse to delete the tree while this is true.
    local running_pids
    running_pids="$(running_build_output_pids)"
    if [[ -n "${running_pids}" ]]; then
        warn "A Chromium built from this tree appears to be running:"
        local pid
        while IFS= read -r pid; do
            [[ -n "${pid}" ]] || continue
            ps -o pid=,comm= -p "${pid}" 2>/dev/null | sed 's/^/[conductor]   /' || true
        done <<< "${running_pids}"
        warn "Quit it before a full or update-build run, or those runs will stop."
        issues=$((issues + 1))
    else
        info "Running browser from tree: none (${SRC_DIR}/out/Default)"
    fi

    # 2. Generated wrapper checkout.
    if [[ -d "${REPO_DIR}" ]]; then
        info "Generated checkout: present (${REPO_DIR})"
        if is_git_worktree "${REPO_DIR}"; then
            info "  git worktree: yes"
        else
            warn "  git worktree: no (checkout looks incomplete)"
            issues=$((issues + 1))
        fi
    else
        info "Generated checkout: absent (a full rebuild would clone it fresh)"
    fi

    # 3. Generated Chromium source: presence plus a shallow completeness probe.
    if [[ -d "${SRC_DIR}" ]]; then
        info "Generated source: present (${SRC_DIR})"
        local required_path
        for required_path in \
            "${SRC_DIR}/DEPS" \
            "${SRC_DIR}/tools/gn/bootstrap/bootstrap.py" \
            "${SRC_DIR}/build" \
            "${SRC_DIR}/chrome"; do
            if [[ -e "${required_path}" ]]; then
                info "  present: ${required_path}"
            else
                warn "  missing: ${required_path}"
                issues=$((issues + 1))
            fi
        done

        # Leftover .rej files mean a patch did not apply cleanly. A half-patched
        # tree must not be trusted for a build.
        local rej_files rej_count
        rej_files="$(find "${SRC_DIR}" -type f -name '*.rej' 2>/dev/null)"
        rej_count="$(printf '%s' "${rej_files}" | grep -c . || true)"
        if [[ "${rej_count}" != "0" ]]; then
            warn "  half-patched: ${rej_count} leftover .rej file(s) found"
            printf '%s\n' "${rej_files}" | sed 's/^/[conductor]   rej: /'
            issues=$((issues + 1))
        else
            info "  no failed-patch (.rej) files"
        fi
    else
        info "Generated source: absent (${SRC_DIR})"
    fi

    # 4. Source-state marker, written only after a clean source prep. Fall back
    #    to the legacy .forge- marker (read-only) so a checkout produced by the
    #    pre-rename script still reports its source state.
    if [[ -f "${SOURCE_STATE_FILE}" ]]; then
        info "Source-state marker: ${SOURCE_STATE_FILE}"
        sed 's/^/[conductor]   /' < "${SOURCE_STATE_FILE}"
    elif [[ -f "${LEGACY_SOURCE_STATE_FILE}" ]]; then
        info "Source-state marker: ${LEGACY_SOURCE_STATE_FILE} (legacy .forge- name; will be rewritten as ${SOURCE_STATE_FILE} on next build)"
        sed 's/^/[conductor]   /' < "${LEGACY_SOURCE_STATE_FILE}"
    else
        info "Source-state marker: absent (last source prep did not finish, or no run yet)"
    fi

    # 5. Build output.
    if [[ -d "${SRC_DIR}/out/Default/Chromium.app" ]]; then
        info "Build output: Chromium.app present"
    else
        info "Build output: Chromium.app absent (no completed build)"
    fi
    if [[ -x "${SRC_DIR}/out/Default/chromedriver" ]]; then
        info "Build output: chromedriver present"
    else
        info "Build output: chromedriver absent"
    fi

    # 6. Last successfully built release.
    if [[ -s "${LAST_BUILT_VERSION_FILE}" ]]; then
        info "Last built release: $(tr -d '[:space:]' < "${LAST_BUILT_VERSION_FILE}")"
    else
        info "Last built release: none recorded yet"
    fi

    section "verify summary"
    if (( issues == 0 )); then
        success "No problems detected in source/build state."
        return 0
    fi
    warn "${issues} issue(s) detected (see messages above)."
    return 1
}

migrate_legacy_state() {
    # This script was formerly forge.sh and kept its state under .forge- names.
    # On first run after the rename, carry the persistent built-version marker
    # forward so ./conductor.sh --check still knows what the last successful
    # build was. We COPY, never move: the legacy file is left in place so an
    # older forge.sh, if ever run again, still finds its own marker. Only the
    # root-level marker is migrated; the source-state marker lives inside the
    # generated build tree and is handled read-only where it is consumed.
    if [[ -f "${LEGACY_LAST_BUILT_VERSION_FILE}" && ! -e "${LAST_BUILT_VERSION_FILE}" ]]; then
        section "migrating legacy state"
        explain "carry the pre-rename built-version marker forward without deleting the original"
        if cp -p "${LEGACY_LAST_BUILT_VERSION_FILE}" "${LAST_BUILT_VERSION_FILE}"; then
            info "Copied ${LEGACY_LAST_BUILT_VERSION_FILE}"
            info "    -> ${LAST_BUILT_VERSION_FILE} (legacy original kept)"
        else
            # Loud, not fatal: a missing marker only makes --check fall back to
            # version.txt, so a failed copy must not block a build.
            warn "Could not migrate ${LEGACY_LAST_BUILT_VERSION_FILE} to ${LAST_BUILT_VERSION_FILE}."
            warn "Continuing without a built-version marker; --check will fall back to version.txt."
        fi
    fi
}

main() {
    parse_args "$@"
    log_init
    print_shell_telemetry
    print_mode

    section "preflight"
    validate_host_layout
    migrate_legacy_state
    load_config
    validate_local_version_consistency

    case "${MODE}" in
        check)
            # --check is read-only:
            # validate local files, ask GitHub for the latest published release,
            # compare it with the last successful local build, then stop.
            # No checkout refresh, no patching, no build.
            check_for_update
            section "done"
            success "Conductor check complete."
            ;;
        verify-only)
            # --verify-only is read-only:
            # report the running-app, checkout, source, and build-output state,
            # then stop. No checkout refresh, no patching, no build.
            local verify_rc=0
            verify_source_and_build_state || verify_rc=$?
            section "done"
            if (( verify_rc == 0 )); then
                success "Verify-only complete: no problems detected."
            else
                warn "Verify-only complete: issues detected (see messages above)."
                exit 1
            fi
            ;;
        clean)
            # --clean is destructive but guarded: it removes only the generated
            # checkout conductor.sh owns, after the running-browser guard and an
            # explicit confirmation. Logs and authored files are preserved.
            clean_generated_state
            section "done"
            success "Conductor clean complete."
            ;;
        full)
            print_run_config

            section "refreshing generated checkout"
            info "Deleting the generated checkout and starting fresh from upstream: ${REPO_DIR}"
            safe_remove_repo_dir
            clone_fresh_repo

            section "restoring source and patches"
            validate_repo_layout
            select_release_tag
            update_version_markers
            align_repo_to_latest_release
            validate_post_checkout_layout
            delete_build_state
            retrieve_sources_and_resources
            apply_source_customizations
            mark_source_state

            section "generating build files"
            write_args_gn
            retrieve_platform_resources

            section "building Chromium.app"
            build_from_scratch
            verify_outputs
            record_built_version

            section "done"
            success "Full rebuild complete: ${LATEST_TAG}"
            info "Build completed in $(format_elapsed_since_start)"
            ;;
        update-build)
            print_run_config
            validate_existing_update_checkout
            check_update_dirty_state

            select_release_tag
            update_version_markers
            align_repo_to_latest_release
            validate_post_checkout_layout

            reset_generated_source_for_update

            apply_source_customizations
            mark_source_state

            section "generating build files"
            write_args_gn
            retrieve_platform_resources

            section "building Chromium.app"
            build_from_scratch
            verify_outputs
            record_built_version

            section "done"
            success "Update-build complete: ${LATEST_TAG}"
            info "Build completed in $(format_elapsed_since_start)"
            ;;
        *)
            error "Internal error: unknown mode '${MODE}'"
            ;;
    esac
}

main "$@"
