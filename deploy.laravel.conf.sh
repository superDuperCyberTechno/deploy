#!/usr/bin/env bash
# deploy.conf.sh — Laravel boilerplate configuration for the deploy script.
# Fetched by: deploy.sh --init laravel

# Domain or IP to connect to over SSH. The script always connects as the
# server root user.
deployment_domain=""

# Path to the SSH private key of the server root user.
ssh_key="$HOME/.ssh/id_ed25519"

# Absolute path of the live site on the server (what the web server
# serves). Defaults to /srv/<project-name> when left unset; relative
# paths are rejected. This is a real directory synced directly by rsync.
# Its parent folder must exist. Symlinks are rejected; deploy to a fresh
# real directory.
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
    # SQLite creates journal files next to the database file.
    "database"
    "storage"
    "bootstrap/cache"
)

# Files/folders ignored during the rsync sync. These are merged with the
# script's hardcoded, project-agnostic ignore list (.git, node_modules,
# ...). The remaining Laravel-specific entries: the SQLite journal
# sidecars (-wal/-shm/-journal, sitting next to the preserved database
# file), the compiled bootstrap cache (rebuilt server-side, e.g.
# php artisan optimize), and generated public artifacts.
ignored=(
    "database/*.sqlite*"
    "bootstrap/cache/*"
    "public/storage"
    "public/hot"
)

# Server-owned paths. rsync never writes into or deletes these, so the
# server copy survives every deployment:
# - "storage" keeps uploads, sessions, logs and cache.
# - ".env" keeps server secrets and configuration.
# - "database/database.sqlite" keeps the SQLite database; migrations and
#   seeders in database/ still sync because only the file is preserved.
# Missing directory entries are recreated with their source subfolder tree
# (empty) on first deploy; missing file entries are created empty. The
# server copy is authoritative afterwards.
preserved=(
    "storage"
    ".env"
    "database/database.sqlite"
)

# ---- Command groups -------------------------------------------------------
# Commands run on the client machine, in the source directory, before the
# sync. Build the production vendor/ locally: the target server has no
# composer, so the synced vendor/ must already be production-ready.
pre_cmds_client=(
    "composer install --quiet --no-dev --optimize-autoloader --prefer-dist --no-interaction --no-progress"
)

# Commands run on the server (over SSH, cd'd into the deployment folder)
# before the sync. The folder and missing preserved paths exist by then.
# Enable maintenance mode before rsync changes files. On a fresh deployment
# folder there is no artisan yet, so skip; no code is being served from it.
pre_cmds_server=(
    "if [ -f artisan ]; then php artisan down; fi"
)

# Commands run on the server after the sync (cd'd into the deployment
# folder), in order. Each entry is arbitrary shell code (conditionals,
# loops, ...) run under bash; a failing command aborts the rest.
post_cmds_server=(
    # Disable maintenance mode when this remote command group exits. The
    # trap also runs when a later command fails, so the site is not left
    # down after a post-sync error.
    "trap 'php artisan up' EXIT"
    # .env is preserved and created empty on first deploy. Warn (remotely)
    # when it is still missing before running artisan.
    "if [ ! -f .env ]; then echo '[deploy][warn] no .env found on the server - artisan commands may fail' >&2; fi"
    # Restart queue workers so they pick up the deployed code.
    "php artisan queue:restart"
    # Clear the cache for schedules using the withoutOverlapping() method
    # this is relevant if a long running process is interrupted and the
    # running flag is never released
    "php artisan schedule:clear-cache"
    # Optimize the config
    "php artisan optimize"
)

# Commands run on the client after the deployment, in the source directory.
# Also run once when a step failed (exit trap), so configs that changed the
# local environment can restore it. Restore the development vendor/ the
# pre_cmds_client step replaced.
post_cmds_client=(
    "composer install --quiet --no-interaction --no-progress"
)
