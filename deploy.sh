#!/usr/bin/env bash
#
# deploy — project-agnostic rsync deployment script.
#
# Syncs a project to a remote server using rsync over SSH. Access is made
# with SSH keys only, as the server's root user.
#
# Flow (the command groups come from the config, so the script stays
# project-agnostic). The deployment_folder is a real directory served
# directly by the web server; there are no snapshots or deployment
# symlinks:
#   1. Run the pre-sync client commands (e.g. composer install --no-dev)
#      in the source directory.
#   2. Prepare the deployment folder on the server: create it and any
#      missing preserved directories/files.
#   3. Run the pre-sync server commands in the deployment folder.
#   4. Sync the project into the deployment folder with rsync. Ignored
#      and preserved paths are excluded, so server-owned runtime state is
#      never overwritten or deleted.
#   5. Apply the web-writable permission pass, then run the post-sync
#      server commands (e.g. php artisan optimize).
#   6. Run the post-sync client commands (e.g. composer install to restore
#      the dev environment). These also run — once — when an earlier step
#      fails, so the local working copy is never left in a production
#      state.
#
# Rollback is done outside this script: restore the previous source state
# with git and deploy again.
#
# Configuration is read from deploy.conf.sh (generatable via: deploy.sh
# --init). See README.md for documentation.

set -euo pipefail

PROG="$(basename "$0")"
readonly PROG

# Semantic version (https://semver.org): bump MAJOR on breaking changes,
# MINOR on backward-compatible additions, PATCH on backward-compatible
# fixes.
readonly VERSION="4.0.1"

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
# "ignored" entries from deploy.conf.sh for every sync. Project-specific
# runtime paths belong in "preserved" instead, so they are bootstrapped on
# first deploy and protected from rsync --delete. Local credentials and
# OS/editor metadata are excluded so they never reach the server. The
# toolchain config files (deploy.conf.sh, deploy.<name>.conf.sh) are
# excluded here; the script itself and the active config are appended by
# name at sync time, so a renamed script stays excluded too.
readonly BASE_IGNORES=(
  ".git/"
  ".env"
  ".env.*"
  "node_modules/"
  ".DS_Store"
  "Thumbs.db"
  "desktop.ini"
  "._*"
  "*.swp"
  "*.swo"
  "*~"
  "auth.json"
  ".npmrc"
  ".yarnrc.yml"
  ".phpunit.result.cache"
  ".phpunit.cache"
  ".php-cs-fixer.cache"
  ".phpcs-cache"
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

Syncs [source] (default: current directory) to a remote server with rsync.
The deployment folder is updated directly; no snapshots or symlinks are
created. Roll back with git and a second deployment.

Options:
    --init [NAME]      Download a boilerplate config from GitHub
                       (default: ./deploy.conf.sh); NAME selects the
                       boilerplate, default 'laravel'. Available:
                       $(available_boilerplates)
    -c, --config PATH  Use PATH as the config file (default: env
                       DEPLOY_CONF or ./deploy.conf.sh)
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
    deployment_folder       Absolute path of the live site on the server
                            (default: /srv/<project-name>); parent must
                            exist
    deployment_user         user:group rsync --chown of the synced files,
                            e.g. root:www-data
    web_writable            Bash array of folders made group-writable via a
                            remote chown/chmod pass (no file transfer)
    ignored                 Bash array of rsync exclude patterns (Laravel
                            defaults in boilerplate)
    preserved               Bash array of server-owned paths that rsync must
                            never touch (e.g. storage, .env, a SQLite
                            file). Missing directory entries are recreated
                            with their source subfolders (empty); missing
                            file entries are created empty.
    pre_cmds_client         Bash array of commands run on the client before
                            the sync
    pre_cmds_server         Bash array of commands run on the server before
                            the sync (in the deployment folder)
    post_cmds_server        Bash array of commands run on the server after
                            the sync (in the deployment folder)
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

# Print the available boilerplate names (hardcoded in BOILERPLATES).
available_boilerplates() {
  printf '%s' "${BOILERPLATES[*]:-none}"
}

# Create the deployment folder on the server and bootstrap preserved
# paths that do not exist yet. Existing preserved files and directories
# are never modified or removed.
prepare_remote_folder() {
  local entry parent rel subdir remote
  log "preparing deployment folder ${deployment_folder}"

  remote="set -e"
  # Refuse to create the folder below a missing parent: mkdir -p would
  # silently build the whole path, hiding a typo in deployment_folder.
  remote+=$'\n'"if [ ! -d '$(shell_quote "$DEPLOY_PARENT")' ]; then"
  remote+=$'\n'"  printf '[deploy][error] deployment parent not found on the server: %s\\n' '$(shell_quote "$DEPLOY_PARENT")' >&2"
  remote+=$'\n'"  exit 1"
  remote+=$'\n'"fi"
  # Refuse to deploy into a symlink: rsync would write through it into the
  # link target instead of a real deployment folder.
  remote+=$'\n'"if [ -L '$(shell_quote "$deployment_folder")' ]; then"
  remote+=$'\n'"  printf '[deploy][error] deployment folder is a symlink; use a fresh real directory: %s\\n' '$(shell_quote "$deployment_folder")' >&2"
  remote+=$'\n'"  exit 1"
  remote+=$'\n'"fi"
  remote+=$'\n'"if [ -e '$(shell_quote "$deployment_folder")' ] && [ ! -d '$(shell_quote "$deployment_folder")' ]; then"
  remote+=$'\n'"  printf '[deploy][error] deployment folder is not a directory: %s\\n' '$(shell_quote "$deployment_folder")' >&2"
  remote+=$'\n'"  exit 1"
  remote+=$'\n'"fi"
  remote+=$'\n'"mkdir -p '$(shell_quote "$deployment_folder")'"

  # Bootstrap missing preserved directories from the source folder tree.
  # Files are not copied: the server copy stays authoritative.
  for entry in "${PRESERVED_DIRS[@]}"; do
    remote+=$'\n'"if [ ! -e '$(shell_quote "$deployment_folder/$entry")' ] && [ ! -L '$(shell_quote "$deployment_folder/$entry")' ]; then"
    remote+=$'\n'"  mkdir -p '$(shell_quote "$deployment_folder/$entry")'"
    # Mirror every subfolder from the source under the preserved entry.
    while IFS= read -r -d '' subdir; do
      rel="${subdir#"$SRC/$entry"}"
      rel="${rel#/}"
      [[ -n "$rel" ]] || continue
      remote+=$'\n'"  mkdir -p '$(shell_quote "$deployment_folder/$entry/$rel")'"
    done < <(find "$SRC/$entry" -type d -print0)
    remote+=$'\n'"  printf '[deploy] created preserved folder: %s\\n' '$(shell_quote "$deployment_folder/$entry")'"
    remote+=$'\n'"fi"
  done

  # Bootstrap missing preserved files empty. Source content is never
  # copied; the server copy stays authoritative.
  for entry in "${PRESERVED_FILES[@]}"; do
    parent="$(dirname "$entry")"
    remote+=$'\n'"if [ ! -e '$(shell_quote "$deployment_folder/$entry")' ] && [ ! -L '$(shell_quote "$deployment_folder/$entry")' ]; then"
    remote+=$'\n'"  mkdir -p '$(shell_quote "$deployment_folder/$parent")'"
    remote+=$'\n'"  touch '$(shell_quote "$deployment_folder/$entry")'"
    remote+=$'\n'"  printf '[deploy] created preserved file: %s\\n' '$(shell_quote "$deployment_folder/$entry")'"
    remote+=$'\n'"fi"
  done

  if ! ssh "${SSH_ARGS[@]}" "root@${deployment_domain}" "bash -s" \
    <<< "$remote"; then
    die "failed to prepare the deployment folder"
  fi
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
preserved=()
pre_cmds_client=()
pre_cmds_server=()
post_cmds_server=()
post_cmds_client=()

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

# Clean and validate preserved: entries are relative paths (nesting
# allowed, e.g. folder1/folder2 preserves exactly folder2), with no
# leading slash, no empty / . / .. path components. Duplicates are
# dropped. Entries are literal server paths, not rsync patterns.
preserved_normalized=()
for entry in "${preserved[@]}"; do
  entry="${entry%/}" # drop trailing slashes
  if [[ -z "$entry" || "$entry" == /* ]]; then
    die "invalid preserved entry: ${entry} (relative paths only)"
  fi
  case "$entry" in
    *[[:cntrl:]]*)
      die "invalid preserved entry: ${entry} (control characters are" \
        "not allowed)"
      ;;
  esac
  IFS='/' read -r -a parts <<< "$entry"
  for part in "${parts[@]}"; do
    if [[ -z "$part" || "$part" == "." || "$part" == ".." ]]; then
      die "invalid preserved entry: ${entry} (no empty, . or .. path" \
        "components)"
    fi
  done
  duplicate=0
  for existing in "${preserved_normalized[@]}"; do
    if [[ "$existing" == "$entry" ]]; then
      duplicate=1
      break
    fi
  done
  (( duplicate )) || preserved_normalized+=("$entry")
done
preserved=("${preserved_normalized[@]}")

if [[ -z "$SRC" ]] || [[ ! -d "$SRC" ]]; then
  die "source directory not found: ${SRC}"
fi
SRC="$(cd "$SRC" && pwd)" # absolute path; also resolves "."

if [[ -z "$deployment_folder" ]]; then
  PROJECT_NAME="$(basename "$SRC")"
  deployment_folder="/srv/${PROJECT_NAME}"
  log "deployment_folder unset, defaulting to ${deployment_folder}"
fi

# deployment_folder is embedded in remote rm, mkdir and rsync commands, so
# require a normalized absolute path: a relative value would resolve
# against root's home on the server. Reject control characters (invisible
# path changes) and . or .. components.
case "$deployment_folder" in
  *[[:cntrl:]]*)
    die "invalid deployment_folder: control characters are not allowed"
    ;;
esac
while [[ "$deployment_folder" == */ ]]; do
  deployment_folder="${deployment_folder%/}" # drop trailing slashes
done
while [[ "$deployment_folder" == *//* ]]; do
  deployment_folder="${deployment_folder//\/\//\/}" # collapse //
done
if [[ -z "$deployment_folder" || "$deployment_folder" == "/" ]]; then
  die "invalid deployment_folder: / (must name a folder below root)"
fi
case "$deployment_folder" in
  /*) ;;
  *) die "invalid deployment_folder: ${deployment_folder} (absolute path" \
    "required)" ;;
esac
case "/${deployment_folder}/" in
  *"/../"*|*"/./"*)
    die "invalid deployment_folder: ${deployment_folder} (. and .." \
      "components are not allowed)"
    ;;
esac

# Preserved entries split by source type. Missing directories are
# recreated (including their subfolders, empty) in the deployment folder.
# Missing file entries are created empty there; source content is never
# copied, so the server copy stays authoritative. Entries absent from the
# source are treated as files (directory entries must exist in the source).
PRESERVED_DIRS=()
PRESERVED_FILES=()
for entry in "${preserved[@]}"; do
  if [[ -d "$SRC/$entry" ]]; then
    PRESERVED_DIRS+=("$entry")
  else
    PRESERVED_FILES+=("$entry")
  fi
done

DEPLOY_PARENT="$(dirname "$deployment_folder")"

require rsync
require ssh

log "config: ${deployment_domain} -> ${deployment_folder} (key: ${ssh_key})"
if [[ -n "${preserved[*]:-}" ]]; then
  log "preserved server paths: ${preserved[*]}"
fi

# --- SSH connection (used by the command groups and the sync) --------------

# Common SSH options: BatchMode keeps ssh from hanging on prompts,
# ConnectTimeout fails fast on unreachable hosts.
readonly SSH_BASE_ARGS=(-o BatchMode=yes -o ConnectTimeout=15)

# Command line for rsync's -e, with the key path escaped for the remote
# shell. SSH_ARGS is the array form used for direct ssh calls.
SSH_CMD="ssh -i $(printf '%q' "$ssh_key") ${SSH_BASE_ARGS[*]}"
SSH_ARGS=(-i "$ssh_key" "${SSH_BASE_ARGS[@]}")

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
  rm -f "$IGNORE_FILE"
}
trap cleanup EXIT

# --- Uncommitted changes safety net ----------------------------------------
# Refuse to run silently on a dirty tree: list the uncommitted changes in
# the source directory and wait for confirmation before any deploy step
# runs. git is optional; --dry-run never waits.
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

# --- Step 1: pre-sync client commands --------------------------------------

if (( DRY_RUN == 1 )); then
  log "dry run: skipping all command groups"
elif (( ${#pre_cmds_client[@]} > 0 )); then
  if ! run_client_cmds "pre-sync" "${pre_cmds_client[@]}"; then
    die "pre-sync client command failed"
  fi
fi

# --- Prepare the deployment folder -----------------------------------------
# Create the folder and bootstrap missing preserved paths. Skipped in
# --dry-run.
if (( DRY_RUN == 1 )); then
  log "dry run: skipping deployment folder preparation"
else
  prepare_remote_folder
fi

# --- Step 2: pre-sync server commands --------------------------------------

if (( DRY_RUN == 0 )) && (( ${#pre_cmds_server[@]} > 0 )); then
  if ! run_remote_cmds "pre-sync" "$deployment_folder" \
    "${pre_cmds_server[@]}"; then
    die "pre-sync server command failed"
  fi
fi

# --- Step 3: sync with rsync ----------------------------------------------

# Base ignores, config ignores, and preserved paths. Preserved entries are
# added as rooted patterns, so rsync never writes into or deletes the
# server-owned copy. They are also excluded from --delete.
printf '%s\n' "${BASE_IGNORES[@]}" > "$IGNORE_FILE"
if (( ${#ignored[@]} > 0 )); then
  printf '%s\n' "${ignored[@]}" >> "$IGNORE_FILE"
fi
# Always exclude the deploy toolchain itself: the script under its current
# name and the active config. Patterns without a slash match at any depth,
# so this holds even when these files are committed in a subfolder.
printf '%s\n' "${PROG}" >> "$IGNORE_FILE"
printf '%s\n' "${CONF##*/}" >> "$IGNORE_FILE"
for entry in "${preserved[@]}"; do
  printf '/%s\n' "$entry" >> "$IGNORE_FILE"
done

# --delete-after removes obsolete files only after the transfer, and
# --delay-updates keeps old files in place until updated files are renamed
# at the end. This shortens the mixed old/new code window; it does not make
# the deployment atomic.
RSYNC_ARGS=(-az --delete-after --delay-updates --exclude-from="$IGNORE_FILE")
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

log "syncing ${SRC}/ -> root@${deployment_domain}:${deployment_folder}/"
if ! rsync "${RSYNC_ARGS[@]}" "${SRC}/" \
  "root@${deployment_domain}:${deployment_folder}/"; then
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
    if ! run_remote_cmds "permission" "$deployment_folder" "${perm_cmds[@]}"; then
      die "failed to apply web-writable permissions"
    fi
  fi
fi

# --- Step 4: post-sync server commands -------------------------------------

if (( DRY_RUN == 0 )) && (( ${#post_cmds_server[@]} > 0 )); then
  if ! run_remote_cmds "post-sync" "$deployment_folder" \
    "${post_cmds_server[@]}"; then
    die "post-sync server command failed"
  fi
fi

# --- Step 5: post-sync client commands -------------------------------------
# Post-sync client commands that did not run here (because a step failed or
# the script never reached this point) are executed by the cleanup trap, so
# POST_CMDS_CLIENT_RUN is set before running to avoid a double execution.

if (( DRY_RUN == 0 )) && (( ${#post_cmds_client[@]} > 0 )); then
  POST_CMDS_CLIENT_RUN=1
  if ! run_client_cmds "post-sync" "${post_cmds_client[@]}"; then
    die "post-sync client command failed"
  fi
fi

log "deployment complete: ${deployment_domain}:${deployment_folder}"
