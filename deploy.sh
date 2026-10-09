#!/usr/bin/env bash
#
# deploy — project-agnostic rsync deployment script.
#
# Syncs a project to a remote server using rsync over SSH. Access is made
# with SSH keys only, as the server's root user.
#
# Flow (the four command groups come from the config, so the script stays
# project-agnostic). The web server serves the project through the
# deployment_folder symlink, which always points at the currently active
# snapshot folder (<name>-<snapshot id>). Every deploy builds a fresh
# snapshot and then switches the symlink:
#   1. Compute the local snapshot id from the git state (latest commit id
#      plus every dirty file with its mtime).
#   2. Read the active snapshot id on the server (the deployment_folder
#      symlink target); when it equals the local id, abort — the source
#      state is already live.
#   3. Run the pre-sync client commands (e.g. composer install --no-dev)
#      in the source directory, then the pre-sync server commands.
#   4. Copy the active snapshot to a new folder named
#      <basename>-<snapshot id> (first deploy: create it empty) and sync
#      the project (minus ignored files) into it with rsync.
#   5. Run the web-writable permission pass and the post-sync server
#      commands (e.g. php artisan optimize) inside the new snapshot.
#   6. Point the deployment_folder symlink at the new snapshot (last
#      server-side step, so the switch is atomic) and prune old snapshots.
#   7. Run the post-sync client commands (e.g. composer install to restore
#      the dev environment). These also run — once — when any earlier step
#      fails, so the local working copy is never left in a production
#      state.
#
#   deploy.sh --rollback skips all of this: it only switches the symlink
#   back to the newest earlier snapshot (no sync, no commands, no pruning).
#
# Configuration is read from deploy.conf.sh (generatable via: deploy.sh
# --init). See extras/deploy/README.md for documentation.

set -euo pipefail

PROG="$(basename "$0")"
readonly PROG

# Semantic version (https://semver.org): bump MAJOR on breaking changes,
# MINOR on backward-compatible additions, PATCH on backward-compatible
# fixes.
readonly VERSION="2.1.0"

# Available boilerplate config names. Hardcoded: the .conf.sh files are
# not shipped next to the script but downloaded from the public GitHub
# repository on demand (deploy.sh --init <name>). Extend this array — and
# add the matching deploy.<name>.conf.sh to the repository — to add a
# boilerplate.
readonly BOILERPLATES=("laravel")

# GitHub repository (owner/name) hosting the boilerplate files.
readonly REPO="superDuperCyberTechno/deploy"

# Base URL of the public GitHub repository hosting the boilerplate files.
readonly BASE_URL="https://raw.githubusercontent.com/${REPO}/main"

# Hardcoded, project-agnostic ignore list. These are merged with the
# "ignored" entries from deploy.conf.sh for every sync. The Laravel-specific
# defaults (storage internals, sqlite database, cached bootstrap files) live
# in the generated boilerplate config instead. The toolchain config files
# (deploy.conf.sh, deploy.<name>.conf.sh) are excluded here; the script
# itself and the active config are appended by name at sync time, so a
# renamed script stays excluded too.
readonly BASE_IGNORES=(
  ".git/"
  ".env"
  ".env.*"
  "node_modules/"
  ".DS_Store"
  "Thumbs.db"
  ".phpunit.result.cache"
  ".phpunit.cache"
  "deploy.*.conf.sh"
)

# Least-privilege permission defaults (rsync --chmod syntax). The main
# sync confines directories to owner rwx / group rx / no world access;
# file permission bits are preserved from the source, so executables keep
# their +x. The web_writable folders get their group-writable permissions
# via a remote chown/chmod command, not via the sync (see below).
readonly MAIN_DIR_CHMOD="Du=rwx,Dg=rx,Do="

# Print the usage/help text.
usage() {
  cat <<EOF
$PROG ${VERSION} — rsync deployment tool

Usage: $PROG [options] [source]

Syncs [source] (default: current directory) to a remote server with rsync,
or rolls the live symlink back with --rollback.

Options:
    --init [NAME]      Download a boilerplate config from GitHub
                       (default: ./deploy.conf.sh); NAME selects the
                       boilerplate, default 'laravel'. Available:
                       $(available_boilerplates)
    -c, --config PATH  Use PATH as the config file (default: env
                       DEPLOY_CONF or ./deploy.conf.sh)
    -r, --rollback     Switch the deployment symlink back to the newest
                       earlier snapshot (requires the config; no sync
                       runs)
    -n, --dry-run      Show what would be synced; skips all command groups
    -v, --verbose      Verbose rsync output
    -V, --version      Show version and exit
    -f, --force        With --init: overwrite an existing config file
    -h, --help         Show this help

Config keys (deploy.conf.sh):
    deployment_domain       Domain/IP to connect to over SSH as root
                            (required)
    ssh_key                 Path to the SSH private key of the server root
                            user (required)
    deployment_folder       Symlink path of the live site on the server
                            (default: /srv/<project-name>); snapshot
                            folders live next to it as <name>-<snapshot id>
    keep_snapshots          Number of previous snapshots kept on the
                            server, next to the active one (default 1;
                            0 keeps all; the active is never pruned)
    deployment_user         user:group rsync --chown of the synced files,
                            e.g. root:www-data
    web_writable            Bash array of folders made group-writable via a
                            remote chown/chmod pass (no file transfer)
    ignored                 Bash array of rsync exclude patterns (Laravel
                            defaults in boilerplate)
    pre_cmds_client         Bash array of commands run on the client before
                            the sync
    pre_cmds_server         Bash array of commands run on the server before
                            the sync (in the currently active deployment)
    post_cmds_server        Bash array of commands run on the server after
                            the sync (in the new snapshot folder)
    post_cmds_client        Bash array of commands run on the client after
                            the deployment (also on failure)
EOF
}

# Print an informational message to stdout.
log() {
  printf '[deploy] %s\n' "$*"
}

# Print a warning message to stderr.
warn() {
  printf '[deploy][warn] %s\n' "$*" >&2
}

# Run a config-declared command group on the client, in the source
# directory. Each entry is arbitrary shell code; the first failing entry
# aborts (nonzero status returned).
run_client_cmds() {
  local label="$1"; shift
  local cmd
  log "running ${#} ${label} command(s) on the client"
  for cmd in "$@"; do
    if ! (cd "$SRC" && bash -c "$cmd"); then
      return 1
    fi
  done
}

# Run a config-declared command group on the server in one ssh session.
# Entries build a bash script (set -e, cd'd into cd_dir) fed to the
# remote bash via stdin; a failing command aborts the rest.
run_remote_cmds() {
  # cd_dir: the directory the commands run in on the server.
  local label="$1" cd_dir="$2"; shift 2
  local cmd remote
  log "running ${#} ${label} command(s) on the server"
  remote="set -e"
  remote+=$'\n'"cd '$(shell_quote "$cd_dir")'"
  for cmd in "$@"; do
    remote+=$'\n'"${cmd}"
  done
  ssh "${SSH_ARGS[@]}" "root@${deployment_domain}" "bash -s" \
    <<< "$remote"
}

# Print the state of the deployment_folder on the server: the resolved
# target path when it is a symlink, 'DIR' for a plain directory, or
# 'NONE' when the folder does not exist. Read-only, so it also runs in
# --dry-run; exits nonzero when ssh fails. Used by both the deploy flow
# and --rollback.
read_active_snapshot() {
  local remote
  remote="set -e"
  remote+=$'\n'"if [ -L '$(shell_quote "$deployment_folder")' ]; then"
  remote+=$'\n'"  readlink -f '$(shell_quote "$deployment_folder")'"
  remote+=$'\n'"elif [ -d '$(shell_quote "$deployment_folder")' ]; then"
  remote+=$'\n'"  printf '%s\\n' 'DIR'"
  remote+=$'\n'"else"
  remote+=$'\n'"  printf '%s\\n' 'NONE'"
  remote+=$'\n'"fi"
  ssh "${SSH_ARGS[@]}" "root@${deployment_domain}" "bash -s" <<< "$remote"
}

# Print an error message to stderr and exit with status 1.
die() {
  printf '[deploy][error] %s\n' "$*" >&2
  exit 1
}

# Quote a string for safe embedding in a single-quoted remote shell context.
shell_quote() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

# Fail with an error if the given tool is not installed.
require() {
  local -r tool="$1"
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: ${tool}"
}

# Compute the snapshot id: the latest commit id plus every dirty file
# with its mtime (git status --porcelain=v1 -z, so paths with spaces are
# read verbatim). Paths are relative to the repository root; the bare
# second path field of a rename record has no status prefix and is skipped
# (the renamed path already describes the change). A deleted file has no
# mtime on disk and is hashed with a placeholder.
snapshot_hash() {
  local root entry path mtime
  root="$(git -C "$SRC" rev-parse --show-toplevel)"
  {
    printf '%s\n' "commit $(git -C "$SRC" rev-parse HEAD)"
    while IFS= read -r -d '' entry; do
      # Regular entries start with two status chars and a space; the bare
      # second field of a rename does not and is skipped.
      [[ "${entry:2:1}" == " " ]] || continue
      path="${entry:3}"
      mtime="-"
      if [[ -e "$root/$path" ]]; then
        mtime="$(stat -c '%y' "$root/$path" 2>/dev/null || printf -- '- ')"
      fi
      printf '%s|%s|%s\n' "${entry:0:2}" "$mtime" "$path"
    done < <(git -C "$SRC" status --porcelain=v1 -z 2>/dev/null)
  } | md5sum | awk '{print $1}'
}

# Print the available boilerplate names (hardcoded in BOILERPLATES).
available_boilerplates() {
  printf '%s' "${BOILERPLATES[*]:-none}"
}

# --- Parse arguments -------------------------------------------------------

CONF="${DEPLOY_CONF:-./deploy.conf.sh}"
SRC="."
MODE="deploy"
BOILERPLATE="laravel"
DRY_RUN=0
VERBOSE=0
FORCE=0

while (( $# > 0 )); do
  case "$1" in
    --init)
      MODE="init"
      if (( $# >= 2 )) && [[ "$2" != -* ]]; then
        BOILERPLATE="$2"
        shift
      fi
      ;;
    -r|--rollback) MODE="rollback" ;;
    -c|--config)
      if (( $# < 2 )); then
        die "option ${1} requires a value"
      fi
      CONF="$2"
      shift
      ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -V|--version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
    -f|--force) FORCE=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      SRC="${1:-.}"
      break
      ;;
    -*)
      die "unknown option: ${1} (see --help)"
      ;;
    *)
      SRC="$1"
      ;;
  esac
  shift
done

# --- Config boilerplate ----------------------------------------------------

# Download a boilerplate config from GitHub and write it to CONF.
if [[ "$MODE" == "init" ]]; then
  # Validate the name against the hardcoded list before touching the
  # network.
  found=0
  for name in "${BOILERPLATES[@]}"; do
    if [[ "$name" == "$BOILERPLATE" ]]; then
      found=1
      break
    fi
  done
  if (( found == 0 )); then
    available="$(available_boilerplates)"
    die "unknown boilerplate '${BOILERPLATE}' (available: ${available})"
  fi

  if [[ -e "$CONF" ]] && (( FORCE == 0 )); then
    die "config already exists: ${CONF} (pass --force to overwrite)"
  fi

  require curl

  URL="${BASE_URL}/deploy.${BOILERPLATE}.conf.sh"
  log "downloading ${URL}"

  # Download to a temporary file first, so a failed download never leaves
  # a partial config behind.
  TMP_CONF="$(mktemp)" || die "failed to create temporary file"
  if ! curl -fsSL "$URL" -o "$TMP_CONF"; then
    rm -f "$TMP_CONF"
    die "failed to download boilerplate '${BOILERPLATE}' from ${URL} (offline?)"
  fi

  if ! mv "$TMP_CONF" "$CONF"; then
    rm -f "$TMP_CONF"
    die "failed to write config: ${CONF}"
  fi

  log "wrote ${BOILERPLATE} boilerplate config to ${CONF}"
  log "edit it, then run: ${PROG}"
  exit 0
fi

# --- Load and validate config ---------------------------------------------

if [[ ! -r "$CONF" ]]; then
  die "config not found or unreadable: ${CONF} (generate one with:" \
    "${PROG} --init)"
fi

# Defaults, overridden by the config file below.
deployment_domain=""
ssh_key=""
deployment_folder=""
deployment_user=""
web_writable=()
ignored=()
pre_cmds_client=()
pre_cmds_server=()
post_cmds_server=()
post_cmds_client=()
keep_snapshots=1

set +u
if ! source "$CONF" 2>/dev/null; then
  die "failed to parse config file: ${CONF}"
fi
set -u

case "$ssh_key" in
  \~/*) ssh_key="$HOME${ssh_key#\~}" ;;
esac

if [[ -z "$deployment_domain" ]]; then
  die "missing required config: deployment_domain"
fi
if [[ -z "$ssh_key" ]]; then
  die "missing required config: ssh_key"
fi
if [[ ! -f "$ssh_key" ]]; then
  die "ssh key not found: ${ssh_key}"
fi

deployment_folder="${deployment_folder%/}" # drop a trailing slash

# Snapshots retention must be a non-negative integer; anything else
# (empty, negative, garbage) disables pruning (keep all) rather than
# failing or deleting unpredictably.
case "$keep_snapshots" in
  ''|*[!0-9]*) keep_snapshots=0 ;;
esac

if [[ -z "$SRC" ]] || [[ ! -d "$SRC" ]]; then
  die "source directory not found: ${SRC}"
fi
SRC="$(cd "$SRC" && pwd)" # absolute path; also resolves "."

if [[ -z "$deployment_folder" ]]; then
  PROJECT_NAME="$(basename "$SRC")"
  deployment_folder="/srv/${PROJECT_NAME}"
  log "deployment_folder unset, defaulting to ${deployment_folder}"
fi

if [[ "$MODE" != "rollback" ]]; then
  require rsync
fi
require ssh

log "config: ${deployment_domain} -> ${deployment_folder} (key: ${ssh_key})"

# --- SSH connection (used by the command groups and the sync) --------------

# Common SSH options: BatchMode keeps ssh from hanging on prompts,
# ConnectTimeout fails fast on unreachable hosts.
readonly SSH_BASE_ARGS=(-o BatchMode=yes -o ConnectTimeout=15)

# Command line for rsync's -e, with the key path escaped for the remote
# shell. SSH_ARGS is the array form used for direct ssh calls.
SSH_CMD="ssh -i $(printf '%q' "$ssh_key") ${SSH_BASE_ARGS[*]}"
SSH_ARGS=(-i "$ssh_key" "${SSH_BASE_ARGS[@]}")

# --- Rollback ---------------------------------------------------------------
# --rollback does one thing: point the deployment_folder symlink back at
# the newest earlier snapshot (deploy order by top-level mtime). No sync,
# no command groups, no pruning, no git checks — only the config and ssh
# are needed. The symlink switch is atomic, exactly like a deploy's last
# step, so the web server keeps serving the active snapshot throughout.
if [[ "$MODE" == "rollback" ]]; then
  ACTIVE_SNAPSHOT=""
  if ! ACTIVE="$(read_active_snapshot)"; then
    die "failed to read the active snapshot on the server"
  fi
  case "$ACTIVE" in
    ""|NONE)
      die "no active deployment found on the server; nothing to roll back"
      ;;
    DIR)
      die "${deployment_folder} is a plain directory — expected a symlink" \
        "pointing at a snapshot (only the snapshot layout is supported)"
      ;;
  esac
  ACTIVE_SNAPSHOT="$ACTIVE"
  log "active snapshot on the server: ${ACTIVE_SNAPSHOT}"

  # Select the newest snapshot deployed strictly before the active one,
  # by deploy order (top-level mtime), so repeated rollbacks walk the
  # deploy history one step back at a time. The snapshot-name glob suffix
  # must stay unquoted so it expands; the dir/base parts are shell-quoted
  # separately. Prints the target path, or 'NONE' when no earlier
  # snapshot exists.
  hex32=""
  for (( i = 0; i < 32; i++ )); do hex32+="[0-9a-f]"; done
  remote="set -e"
  remote+=$'\n'"active_mtime=\"\$(stat -c '%y' '$(shell_quote "$ACTIVE_SNAPSHOT")' 2>/dev/null || printf -- 0)\""
  remote+=$'\n'"rollback_target=\"\$(for s in '$(shell_quote "$(dirname "$deployment_folder")")'/'$(shell_quote "$(basename "$deployment_folder")")'-${hex32}; do"
  remote+=$'\n'"  [ -d \"\$s\" ] || continue"
  remote+=$'\n'"  m=\"\$(stat -c '%y' \"\$s\" 2>/dev/null || printf -- 0)\""
  remote+=$'\n'"  [[ \$m < \$active_mtime ]] || continue"
  remote+=$'\n'"  printf '%s\\t%s\\n' \"\$m\" \"\$s\""
  remote+=$'\n'"done | sort | tail -n 1 | cut -f2-)\""
  remote+=$'\n'"if [ -n \"\$rollback_target\" ]; then"
  remote+=$'\n'"  printf '%s\\n' \"\$rollback_target\""
  remote+=$'\n'"else"
  remote+=$'\n'"  printf '%s\\n' 'NONE'"
  remote+=$'\n'"fi"
  if ! TARGET="$(ssh "${SSH_ARGS[@]}" "root@${deployment_domain}" "bash -s" \
    <<< "$remote")"; then
    die "failed to read the rollback candidates on the server"
  fi

  if [[ "$TARGET" == "NONE" ]]; then
    die "no earlier snapshot found next to ${deployment_folder}; nothing" \
      "to roll back to"
  fi

  if (( DRY_RUN == 1 )); then
    log "dry run: would switch ${deployment_folder} -> ${TARGET}"
    exit 0
  fi

  # Atomic switch, same as the deploy's final step; nothing else changes,
  # so the next deploy prunes as usual.
  if ! ssh "${SSH_ARGS[@]}" "root@${deployment_domain}" \
    "ln -sfn $(shell_quote "$TARGET") $(shell_quote "$deployment_folder")"; then
    die "failed to switch the deployment symlink to ${TARGET}"
  fi
  log "deployment rolled back: ${deployment_folder} -> ${TARGET}"
  exit 0
fi

# --- Snapshot id and paths ------------------------------------------------
# The snapshot id must be a pure function of the local source state, so a
# second deploy of an unmodified source can be detected and skipped.
# Deriving it requires git (commit id + dirty-file list); the snapshot is
# named <basename-of-deployment_folder>-<id> and lives next to the
# deployment_folder symlink.
if ! command -v git >/dev/null 2>&1; then
  die "required tool not found: git (snapshot ids are built from the" \
    "repository state)"
fi
if ! git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "source is not a git work tree: ${SRC}"
fi
SNAPSHOT_HASH="$(snapshot_hash)" || die "failed to compute snapshot id"
if [[ -z "$SNAPSHOT_HASH" ]]; then
  die "failed to compute snapshot id"
fi
SNAPSHOT_DIR="$(dirname "$deployment_folder")/$(basename "$deployment_folder")-${SNAPSHOT_HASH}"
SNAPSHOT_BUILT=0
SNAPSHOT_ACTIVE=0
log "snapshot id ${SNAPSHOT_HASH} -> ${SNAPSHOT_DIR}"

# --- Command-group state (post_cmds_client also runs on failure) -----------

IGNORE_FILE="$(mktemp)" || die "failed to create temporary ignore file"

POST_CMDS_CLIENT_RUN=0

# Run the post-sync client commands once when the script exits before its
# regular post-sync step (i.e. a step failed), so configs that modified the
# local environment (e.g. composer --no-dev) can restore it. Remove the
# transient ignore file in any case.
cleanup() {
  if (( POST_CMDS_CLIENT_RUN == 0 )) && (( DRY_RUN == 0 )) \
    && (( ${#post_cmds_client[@]} > 0 )); then
    log "deployment did not complete; running post-sync client commands" \
      "(restore)"
    run_client_cmds "post-sync" "${post_cmds_client[@]}" >&2 || true
  fi
  # A failed deploy leaves an unused, possibly partial snapshot on the
  # server; remove it so disk is not littered. The active snapshot is
  # untouched: the symlink switch happens only after all fallible steps,
  # setting SNAPSHOT_ACTIVE.
  if (( SNAPSHOT_BUILT == 1 )) && (( SNAPSHOT_ACTIVE == 0 )) \
    && (( DRY_RUN == 0 )); then
    log "removing incomplete snapshot ${SNAPSHOT_DIR}"
    ssh "${SSH_ARGS[@]}" "root@${deployment_domain}" \
      "rm -rf -- $(shell_quote "$SNAPSHOT_DIR")" >/dev/null 2>&1 || true
  fi
  rm -f "$IGNORE_FILE"
}
trap cleanup EXIT

# --- Active snapshot check --------------------------------------------------
# The deployment_folder symlink names the live snapshot. Read its target:
# a missing folder is a first deploy with no active snapshot; a plain
# directory is a legacy/unsupported layout and aborts. Read-only, so it
# also runs in --dry-run.
ACTIVE_SNAPSHOT=""
if ! ACTIVE="$(read_active_snapshot)"; then
  die "failed to read the active snapshot on the server"
fi

case "$ACTIVE" in
  ""|NONE)
    log "no active deployment found on the server"
    ;;
  DIR)
    die "${deployment_folder} is a plain directory — expected a symlink" \
      "pointing at a snapshot (only the snapshot layout is supported," \
      "no legacy deployments are migrated)"
    ;;
  *)
    log "active snapshot on the server: ${ACTIVE}"
    ACTIVE_SNAPSHOT="$ACTIVE"
    ;;
esac

# Skip when the active snapshot already carries the local snapshot id: the
# deployed source state is exactly the current one. Nothing ran yet, so no
# post-sync client restore is needed — the flag below marks it as done so
# the exit trap stays idle.
if [[ "$(basename "$ACTIVE_SNAPSHOT")" == *"${SNAPSHOT_HASH}" ]]; then
  log "deployment skipped: snapshot ${SNAPSHOT_HASH} is already live"
  POST_CMDS_CLIENT_RUN=1
  exit 0
fi

# --- Uncommitted changes safety net ----------------------------------------
# Refuse to run silently on a dirty tree: list the uncommitted changes in
# the source directory and wait for confirmation before the command groups
# (which may modify the local environment) start. Only applies when git is
# installed and the source is a work tree; --dry-run never waits.
if command -v git >/dev/null 2>&1 \
  && git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -t dirty_lines < <(git -C "$SRC" status --porcelain 2>/dev/null || true)
  if (( ${#dirty_lines[@]} > 0 )); then
    warn "uncommitted changes detected in ${SRC}:"
    for line in "${dirty_lines[@]}"; do
      warn "  ${line}"
    done
    if (( DRY_RUN == 1 )); then
      warn "dry run: no confirmation needed"
    elif [[ -t 0 ]]; then
      warn "Press Enter to continue or Ctrl+C to abort."
      read -r
    else
      warn "stdin is not a terminal; continuing without confirmation"
    fi
  fi
fi

# --- Step 1: pre-sync commands ---------------------------------------------

if (( DRY_RUN == 1 )); then
  log "dry run: skipping all command groups"
elif (( ${#pre_cmds_client[@]} > 0 )); then
  if ! run_client_cmds "pre-sync" "${pre_cmds_client[@]}"; then
    die "pre-sync client command failed"
  fi
fi

if (( DRY_RUN == 0 )) && (( ${#pre_cmds_server[@]} > 0 )); then
  if ! run_remote_cmds "pre-sync" "$deployment_folder" "${pre_cmds_server[@]}"; then
    die "pre-sync server command failed"
  fi
fi

# --- Build the new snapshot folder -----------------------------------------
# The new snapshot starts as a recursive copy of the currently active one,
# so server-side state that is never synced (.env, storage writes, ...)
# carries over; rsync then overwrites it with the current source. A
# leftover folder from an interrupted deploy is replaced. First deploy:
# the snapshot is created empty. Never run in --dry-run.
if (( DRY_RUN == 1 )); then
  log "dry run: skipping snapshot build"
else
  log "building snapshot ${SNAPSHOT_DIR}"
  remote="set -e"
  remote+=$'\n'"if [ -d '$(shell_quote "$SNAPSHOT_DIR")' ]; then"
  remote+=$'\n'"  rm -rf '$(shell_quote "$SNAPSHOT_DIR")'"
  remote+=$'\n'"fi"
  remote+=$'\n'"if [ -n '$(shell_quote "$ACTIVE_SNAPSHOT")' ] \
&& [ -d '$(shell_quote "$ACTIVE_SNAPSHOT")' ]; then"
  remote+=$'\n'"  cp -a '$(shell_quote "$ACTIVE_SNAPSHOT")' '$(shell_quote "$SNAPSHOT_DIR")'"
  remote+=$'\n'"else"
  remote+=$'\n'"  mkdir -p '$(shell_quote "$SNAPSHOT_DIR")'"
  remote+=$'\n'"fi"
  if ! ssh "${SSH_ARGS[@]}" "root@${deployment_domain}" "bash -s" \
    <<< "$remote"; then
    die "failed to build the snapshot folder"
  fi
  SNAPSHOT_BUILT=1
fi

# --- Step 2: sync with rsync ----------------------------------------------

printf '%s\n' "${BASE_IGNORES[@]}" > "$IGNORE_FILE"
if (( ${#ignored[@]} > 0 )); then
  printf '%s\n' "${ignored[@]}" >> "$IGNORE_FILE"
fi
# Always exclude the deploy toolchain itself: the script under its current
# name and the active config. Patterns without a slash match at any depth,
# so this holds even when these files are committed in a subfolder.
printf '%s\n' "${PROG}" >> "$IGNORE_FILE"
printf '%s\n' "${CONF##*/}" >> "$IGNORE_FILE"

RSYNC_ARGS=(-az --delete --exclude-from="$IGNORE_FILE")
RSYNC_ARGS+=(--chmod="$MAIN_DIR_CHMOD")
if [[ -n "$deployment_user" ]]; then
  # Chown transferred files on the receiver; without this they would keep
  # the local developer's uid once synced. Root ownership with the web
  # server's group (e.g. root:www-data) is the least-privilege default.
  RSYNC_ARGS+=(--chown="$deployment_user")
fi
RSYNC_ARGS+=(-e "$SSH_CMD")
if (( VERBOSE == 1 )); then
  RSYNC_ARGS+=(-v)
fi
if (( DRY_RUN == 1 )); then
  RSYNC_ARGS+=(-n)
fi

log "syncing ${SRC}/ -> root@${deployment_domain}:${SNAPSHOT_DIR}/"
if ! rsync "${RSYNC_ARGS[@]}" "${SRC}/" \
  "root@${deployment_domain}:${SNAPSHOT_DIR}/"; then
  die "rsync failed"
fi

# --- Web-server writable folders -------------------------------------------
# A remote permission pass, not a sync: the listed folders become
# group-writable with setgid — directories 2770, files 660, ownership from
# deployment_user — so the web server can write there while root keeps
# ownership. Nothing is transferred here, so ignored files can never leave
# the client. Runs before the post-sync server commands, so e.g. php
# artisan optimize can write bootstrap/cache immediately.

if (( ${#web_writable[@]} > 0 )); then
  if (( DRY_RUN == 1 )); then
    log "dry run: skipping web-writable permission pass"
  else
    # Build the remote command list; paths are shell-quoted for the remote
    # bash session. chown only runs when deployment_user is set.
    perm_cmds=()
    quoted_paths=''
    for w in "${web_writable[@]}"; do
      w="${w%/}" # drop a trailing slash
      quoted_paths+=" '$(shell_quote "$w")'"
    done
    if [[ -n "$deployment_user" ]]; then
      perm_cmds+=("chown -R '$(shell_quote "$deployment_user")'${quoted_paths}")
    fi
    for w in "${web_writable[@]}"; do
      w="${w%/}" # drop a trailing slash
      perm_cmds+=(
        "find '$(shell_quote "$w")' -type d -exec chmod 2770 {} +"
        "find '$(shell_quote "$w")' -type f -exec chmod 660 {} +"
      )
    done

    log "applying web-server writable permissions to: ${web_writable[*]}"
    if ! run_remote_cmds "permission" "$SNAPSHOT_DIR" "${perm_cmds[@]}"; then
      die "failed to apply web-writable permissions"
    fi
  fi
fi

# --- Step 3: post-sync server commands -------------------------------------

if (( DRY_RUN == 0 )) && (( ${#post_cmds_server[@]} > 0 )); then
  if ! run_remote_cmds "post-sync" "$SNAPSHOT_DIR" "${post_cmds_server[@]}"; then
    die "post-sync server command failed"
  fi
fi

# --- Switch the symlink (last server-side step) ----------------------------
# Point the deployment_folder symlink at the new snapshot: the web server
# keeps serving the previous snapshot until now, so this step is the
# atomic switch: ln -sfn replaces the existing symlink (or creates the
# first one). Old snapshots beyond keep_snapshots are then pruned; the
# just-linked active snapshot is never touched. Skipped in --dry-run.
if (( DRY_RUN == 1 )); then
  log "dry run: would switch ${deployment_folder} -> ${SNAPSHOT_DIR}"
else
  # Mark the snapshot as active before the switch runs: should the remote
  # session die mid-switch, the (complete) snapshot must not be cleaned up
  # like a partial one — worst case it stays as an unused snapshot that
  # the next deploy prunes.
  SNAPSHOT_ACTIVE=1
  remote="set -e"
  # touch stamps the deploy time: cp -a preserves the top-level mtime, so
  # without it snapshots would not order chronologically for the pruning.
  remote+=$'\n'"touch '$(shell_quote "$SNAPSHOT_DIR")'"
  # ln -sfn atomically replaces an existing symlink and creates a missing
  # one (a dangling symlink from a vanished snapshot is also replaced).
  remote+=$'\n'"ln -sfn '$(shell_quote "$SNAPSHOT_DIR")' '$(shell_quote "$deployment_folder")'"
  if (( keep_snapshots > 0 )); then
    # Prune: keep the newest keep_snapshots snapshots besides the active
    # one (sorted by mtime, i.e. deploy order), delete the rest.
    hex32=""
    for (( i = 0; i < 32; i++ )); do hex32+="[0-9a-f]"; done
    # The snapshot-name glob suffix must stay unquoted so it actually
    # expands; the dir/base parts are shell-quoted separately.
    remote+=$'\n'"for s in '$(shell_quote "$(dirname "$deployment_folder")")'/'$(shell_quote "$(basename "$deployment_folder")")'-${hex32}; do"
    remote+=$'\n'"  [ -d \"\$s\" ] || continue"
    remote+=$'\n'"  [ \"\$s\" = '$(shell_quote "$SNAPSHOT_DIR")' ] && continue"
    remote+=$'\n'"  printf '%s\\t%s\\n' \"\$(stat -c '%y' \"\$s\" 2>/dev/null || printf -- 0)\" \"\$s\""
    # keep_snapshots counts non-active snapshots, hence the +1: the active
    # one is already excluded above, so delete from position N+1 onward.
    remote+=$'\n'"done | sort -r | tail -n +$((keep_snapshots + 1)) | cut -f2- | while IFS= read -r d; do"
    remote+=$'\n'"  rm -rf \"\$d\""
    remote+=$'\n'"done || true"
  fi
  if ! ssh "${SSH_ARGS[@]}" "root@${deployment_domain}" "bash -s" \
    <<< "$remote"; then
    die "failed to switch the deployment symlink"
  fi
fi

# --- Step 4: post-sync client commands -------------------------------------
# Post-sync client commands that did not run here (because a step failed or
# the script never reached this point) are executed by the cleanup trap, so
# POST_CMDS_CLIENT_RUN is set before running to avoid a double execution.

if (( DRY_RUN == 0 )) && (( ${#post_cmds_client[@]} > 0 )); then
  POST_CMDS_CLIENT_RUN=1
  if ! run_client_cmds "post-sync" "${post_cmds_client[@]}"; then
    die "post-sync client command failed"
  fi
fi

log "deployment complete: ${deployment_folder} -> ${SNAPSHOT_DIR}"
