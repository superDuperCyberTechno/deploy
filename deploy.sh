#!/usr/bin/env bash
#
# deploy — project-agnostic rsync deployment script.
#
# Syncs a project to a remote server using rsync over SSH. Access is made
# with SSH keys only, as the server's root user.
#
# Flow:
#   1. Install the production environment locally (composer install --no-dev).
#      Required, because the target server has no composer installed and the
#      synced vendor/ directory must be production-ready.
#   2. Sync the project (minus ignored files) with rsync to the server.
#   3. Run the post-deployment commands on the server (e.g. php artisan
#      optimize).
#   4. Re-install the development environment locally (composer install).
#      This also runs when any earlier step fails, so the local working copy
#      is never left in a production state.
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
# in the generated boilerplate config instead.
readonly BASE_IGNORES=(
  ".git/"
  ".env"
  ".env.*"
  "node_modules/"
  ".DS_Store"
  "Thumbs.db"
  ".phpunit.result.cache"
  ".phpunit.cache"
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
    -n, --dry-run      Show what would be synced; skips composer steps and
                       remote commands
    -v, --verbose      Verbose rsync output
    --no-composer      Skip the production install / dev restore composer
                       steps
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
    post_deployment_commands  Bash array of commands run on the server
                              after a successful sync
EOF
}

# Print an informational message to stdout.
log() {
  printf '[deploy] %s\n' "$*"
}

# Print a warning message to stderr. The message body is red when stderr
# is a terminal, so piped/redirected output stays free of escape codes.
warn() {
  if [[ -t 2 ]]; then
    printf '[deploy][warn] \033[31m%s\033[0m\n' "$*" >&2
  else
    printf '[deploy][warn] %s\n' "$*" >&2
  fi
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
NO_COMPOSER=0
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
    --no-composer) NO_COMPOSER=1 ;;
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
post_deployment_commands=()

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

if ! command -v composer >/dev/null 2>&1; then
  warn "composer not found locally — skipping the production install / dev" \
    "restore; vendor/ synced as-is"
  NO_COMPOSER=1
fi

log "config: ${deployment_domain} -> ${deployment_folder} (key: ${ssh_key})"
# --- State for dev-environment restore (also on failure) -------------------

IGNORE_FILE="$(mktemp)" || die "failed to create temporary ignore file"

PRODUCTION_VENDOR=0
RESTORED=0

# Restore the local development environment and remove the transient ignore
# file when the script exits.
cleanup() {
  if (( PRODUCTION_VENDOR == 1 )) && (( RESTORED == 0 )); then
    warn "restoring local development environment (composer install)"
    composer install --quiet --no-interaction --no-progress || true
  fi
  rm -f "$IGNORE_FILE"
}
trap cleanup EXIT

# --- Step 1: production environment (local) --------------------------------

if (( DRY_RUN == 1 )); then
  log "dry run: skipping composer steps and remote commands"
elif (( NO_COMPOSER == 1 )); then
  log "skipping composer production install (--no-composer)"
else
  log "installing production dependencies locally (composer install --no-dev)"
  composer install --quiet --no-dev --optimize-autoloader --prefer-dist \
    --no-interaction --no-progress
  PRODUCTION_VENDOR=1
fi

# --- Step 2: sync with rsync ----------------------------------------------

# Common SSH options: BatchMode keeps ssh from hanging on prompts,
# ConnectTimeout fails fast on unreachable hosts.
readonly SSH_BASE_ARGS=(-o BatchMode=yes -o ConnectTimeout=15)

# Command line for rsync's -e, with the key path escaped for the remote
# shell. SSH_ARGS is the array form used for direct ssh calls.
SSH_CMD="ssh -i $(printf '%q' "$ssh_key") ${SSH_BASE_ARGS[*]}"
SSH_ARGS=(-i "$ssh_key" "${SSH_BASE_ARGS[@]}")

printf '%s\n' "${BASE_IGNORES[@]}" > "$IGNORE_FILE"
if (( ${#ignored[@]} > 0 )); then
  printf '%s\n' "${ignored[@]}" >> "$IGNORE_FILE"
fi

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
  die "rsync failed; local dev environment is being restored"
fi

# --- Web-server writable folders -------------------------------------------
# rsync --chmod is global, so the folders listed in web_writable get their
# permissions via a dedicated, filter-restricted second pass (dirs and files
# only under the listed paths). Run before the post-deployment commands, so
# e.g. php artisan optimize can write bootstrap/cache immediately.

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
    die "permission pass failed; local dev environment is being restored"
  fi
fi

# --- Step 3: post-deployment commands (remote) -----------------------------

if (( DRY_RUN == 1 )); then
  log "dry run: skipping post-deployment commands"
elif (( ${#post_deployment_commands[@]} > 0 )); then
  log "checking for .env on the server"

  if ! ssh "${SSH_ARGS[@]}" "root@${deployment_domain}" \
    "test -f '$(shell_quote "$deployment_folder")/.env'"; then
    warn "no .env found on the server in ${deployment_folder} — artisan" \
      "commands will likely fail"
  fi

  log "running ${#post_deployment_commands[@]} post-deployment command(s)" \
    "on the server"

  remote="set -e; cd '$(shell_quote "$deployment_folder")'"
  for cmd in "${post_deployment_commands[@]}"; do
    remote+=" && ${cmd}"
  done

  if ! ssh "${SSH_ARGS[@]}" "root@${deployment_domain}" "$remote"; then
    die "post-deployment commands failed; local dev environment is being" \
      "restored"
  fi
else
  log "no post-deployment commands configured"
fi

# --- Step 4: development environment (local) -------------------------------

if (( PRODUCTION_VENDOR == 1 )); then
  log "re-installing local development environment (composer install)"
  composer install --quiet --no-interaction --no-progress
  RESTORED=1
  PRODUCTION_VENDOR=0
fi

log "deployment complete"
