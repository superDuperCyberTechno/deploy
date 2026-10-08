#!/usr/bin/env bash
#
# deploy — project-agnostic rsync deployment script.
#
# Syncs a project to a remote server using rsync over SSH. Access is made
# with SSH keys only, as the server's root user.
#
# Flow (the four command groups come from the config, so the script stays
# project-agnostic):
#   1. Run the pre-sync client commands (e.g. composer install --no-dev) in
#      the source directory.
#   2. Run the pre-sync server commands (over SSH).
#   3. Sync the project (minus ignored files) with rsync to the server.
#   4. Run the post-sync server commands (e.g. php artisan optimize).
#   5. Run the post-sync client commands (e.g. composer install to restore
#      the dev environment). These also run — once — when any earlier step
#      fails, so the local working copy is never left in a production state.
#
# Configuration is read from deploy.conf.sh (generatable via: deploy.sh
# --init). See extras/deploy/README.md for documentation.

set -euo pipefail

PROG="$(basename "$0")"
readonly PROG

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

# Permissions applied (rsync --chmod syntax) to the folders listed in the
# web_writable config entry: directories group-writable with setgid (so
# files created by the web server inherit the group), files group-writable.
readonly WEB_WRITABLE_CHMOD="Du=rwx,Dg=rwxs,Do=rx,Fu=rw,Fg=rw,Fo=r"

# Print the usage/help text.
usage() {
  cat <<EOF
Usage: $PROG [options] [source]

Syncs [source] (default: current directory) to a remote server with rsync.

Options:
    --init [NAME]      Download a boilerplate config from GitHub
                       (default: ./deploy.conf.sh); NAME selects the
                       boilerplate, default 'laravel'. Available:
                       $(available_boilerplates)
    -c, --config PATH  Use PATH as the config file (default: env
                       DEPLOY_CONF or ./deploy.conf.sh)
    -n, --dry-run      Show what would be synced; skips all command groups
    -v, --verbose      Verbose rsync output
    -f, --force        With --init: overwrite an existing config file
    -h, --help         Show this help

Config keys (deploy.conf.sh):
    deployment_domain       Domain/IP to connect to over SSH as root
                            (required)
    ssh_key                 Path to the SSH private key of the server root
                            user (required)
    deployment_folder       Remote folder to sync into (default:
                            /srv/<project-name>)
    deployment_user         user:group rsync --chown of the synced files,
                            e.g. www-data:www-data
    web_writable            Bash array of folders made web-server writable
                            via rsync --chmod
    ignored                 Bash array of rsync exclude patterns (Laravel
                            defaults in boilerplate)
    pre_cmds_client         Bash array of commands run on the client before
                            the sync
    pre_cmds_server         Bash array of commands run on the server before
                            the sync
    post_cmds_server        Bash array of commands run on the server after
                            the sync
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
# Entries build a bash script (set -e, cd'd into deployment_folder) fed to
# the remote bash via stdin; a failing command aborts the rest.
run_remote_cmds() {
  local label="$1"; shift
  local cmd remote
  log "running ${#} ${label} command(s) on the server"
  remote="set -e"
  remote+=$'\n'"cd '$(shell_quote "$deployment_folder")'"
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

if [[ -z "$SRC" ]] || [[ ! -d "$SRC" ]]; then
  die "source directory not found: ${SRC}"
fi
SRC="$(cd "$SRC" && pwd)" # absolute path; also resolves "."

if [[ -z "$deployment_folder" ]]; then
  PROJECT_NAME="$(basename "$SRC")"
  deployment_folder="/srv/${PROJECT_NAME}"
  log "deployment_folder unset, defaulting to ${deployment_folder}"
fi

require rsync
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
  if ! run_remote_cmds "pre-sync" "${pre_cmds_server[@]}"; then
    die "pre-sync server command failed"
  fi
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
if [[ -n "$deployment_user" ]]; then
  # Root chowns transferred files on the receiver; without this the files
  # would keep the local developer's uid once synced.
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
# rsync --chmod is global, so the folders listed in web_writable get their
# permissions via a dedicated, filter-restricted second pass (dirs and files
# only under the listed paths). Run before the post-sync server commands,
# so e.g. php artisan optimize can write bootstrap/cache immediately.

if (( ${#web_writable[@]} > 0 )); then
  CHMOD_ARGS=(-a --chmod="$WEB_WRITABLE_CHMOD")
  if [[ -n "$deployment_user" ]]; then
    CHMOD_ARGS+=(--chown="$deployment_user")
  fi
  for w in "${web_writable[@]}"; do
    w="${w%/}" # drop a trailing slash
    CHMOD_ARGS+=(--filter="+ ${w}/***")
  done
  CHMOD_ARGS+=(--filter="- *")
  CHMOD_ARGS+=(-e "$SSH_CMD")
  if (( VERBOSE == 1 )); then
    CHMOD_ARGS+=(-v)
  fi
  if (( DRY_RUN == 1 )); then
    CHMOD_ARGS+=(-n)
  fi

  log "applying web-server writable permissions to: ${web_writable[*]}"

  if ! rsync "${CHMOD_ARGS[@]}" "${SRC}/" \
    "root@${deployment_domain}:${deployment_folder}/"; then
    die "permission pass failed"
  fi
fi

# --- Step 3: post-sync server commands -------------------------------------

if (( DRY_RUN == 0 )) && (( ${#post_cmds_server[@]} > 0 )); then
  if ! run_remote_cmds "post-sync" "${post_cmds_server[@]}"; then
    die "post-sync server command failed"
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

log "deployment complete"
