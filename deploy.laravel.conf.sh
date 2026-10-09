#!/usr/bin/env bash
# deploy.conf.sh — Laravel boilerplate configuration for the deploy script.
# Fetched by: deploy.sh --init laravel

# Domain or IP to connect to over SSH. The script always connects as the
# server root user.
deployment_domain=""

# Path to the SSH private key of the server root user.
ssh_key="$HOME/.ssh/id_ed25519"

# Symlink path of the live site on the server (what the web server
# serves). Defaults to /srv/<project-name> when left unset. Each deploy
# builds a snapshot folder <name>-<snapshot id> next to it and switches
# this symlink to the newest snapshot as the last server-side step.
# deployment_folder="/srv/<project-name>"

# user:group assigned to every synced file via rsync --chown. Root
# ownership with the web server's group: the web server can read and
# traverse the code via the group, but only write inside web_writable
# (group-writable, setgid). Leave empty to keep everything root-owned —
# then give the web server group access yourself, or it cannot read the
# 750 directories.
deployment_user="root:www-data"

# Folders the web server must write into at runtime. A remote permission
# pass (no file transfer) makes them group-writable with setgid:
# directories 2770, files 660, ownership deployment_user — the web server
# writes via the group while root keeps ownership. No world access.
web_writable=(
    # "database" #uncomment this if you use the SQLite database
    "storage"
    "bootstrap/cache"
)

# Files/folders ignored during the rsync sync. These are merged with the
# script's hardcoded, project-agnostic ignore list (.git, .env, .env.*,
# node_modules, ...). The defaults below are the Laravel-specific ones:
# the storage/ internals must never be overwritten from the repository, the
# sqlite file is managed on the server, and the compiled bootstrap cache is
# rebuilt server-side (e.g. php artisan optimize).
ignored=(
    "storage/app/*"
    "storage/framework/cache/*"
    "storage/framework/sessions/*"
    "storage/framework/views/*"
    "storage/logs/*"
    "storage/*.key"
    "database/*.sqlite*"
    "bootstrap/cache/*"
    "public/storage"
    "public/hot"
)

# Entries shared between snapshots via the persistent home
# <deployment_folder>-shared: each is migrated into the home once and
# symlinked into every snapshot, so the storage folder (uploads,
# sessions, cache, logs) is a single copy on the server instead of being
# copied with every deploy — no torn copies, and sessions survive
# deploys and rollbacks. Nested paths are allowed too (e.g.
# "storage/app/public" shares exactly that folder). .env is always
# shared this way; top-level entries you drop into the home yourself are
# linked automatically.
shared_links=(
    "storage"
)

# ---- Command groups -------------------------------------------------------
# Commands run on the client machine, in the source directory, before the
# sync. Build the production vendor/ locally: the target server has no
# composer, so the synced vendor/ must already be production-ready.
pre_cmds_client=(
    "composer install --quiet --no-dev --optimize-autoloader --prefer-dist --no-interaction --no-progress"
)

# Commands run on the server (over SSH, cd'd into the currently active
# deployment) before the sync. Nothing needed for Laravel.
pre_cmds_server=()

# Commands run on the server after the sync (cd'd into the new snapshot
# folder), in order. Each entry is arbitrary shell code (conditionals,
# loops, ...) run under bash; a failing command aborts the rest.
post_cmds_server=(
    # .env is always excluded from the sync and lives in the shared home
    # (<deployment_folder>-shared), symlinked into every snapshot. Warn
    # (remotely) when it is missing before running artisan — on a first
    # deploy (fresh server) place it in the shared home and redeploy, or
    # create it there. The warn goes to stderr with the [deploy][warn]
    # prefix, like local warnings.
    "if [ ! -f .env ]; then echo '[deploy][warn] no .env found on the server - artisan commands may fail' >&2; fi"
    "php artisan optimize"
    # Restart queue workers so they pick up the deployed code.
    "php artisan queue:restart"
    # Clear the cache for schedules using the withoutOverlapping() method
    # this is relevant if a long running process is interrupted and the
    # running flag is never released
    "php artisan schedule:clear-cache"
)

# Commands run on the client after the deployment, in the source directory.
# Also run once when a step failed (exit trap), so configs that changed the
# local environment can restore it. Restore the development vendor/ the
# pre_cmds_client step replaced.
post_cmds_client=(
    "composer install --quiet --no-interaction --no-progress"
)
