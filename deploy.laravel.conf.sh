#!/usr/bin/env bash
# deploy.conf.sh — Laravel boilerplate configuration for the deploy script.
# Fetched by: deploy.sh --init laravel

# Domain or IP to connect to over SSH. The script always connects as the
# server root user.
deployment_domain=""

# Path to the SSH private key of the server root user.
ssh_key="$HOME/.ssh/id_ed25519"

# Remote folder the project is synced to. Defaults to /srv/<project-name>
# when left unset.
# deployment_folder="/srv/<project-name>"

# user:group assigned to every synced file via rsync --chown. Typically the
# web server user; leave empty to keep the local file ownership.
deployment_user="www-data:www-data"

# Folders that must stay writable by the web server process. Permissions are
# applied via rsync --chmod in a dedicated pass: directories become
# group-writable with setgid (2775), files group-writable (664), the group
# being deployment_user's group.
web_writable=(
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

# ---- Command groups -------------------------------------------------------
# Commands run on the client machine, in the source directory, before the
# sync. Build the production vendor/ locally: the target server has no
# composer, so the synced vendor/ must already be production-ready.
pre_cmds_client=(
    "composer install --quiet --no-dev --optimize-autoloader --prefer-dist --no-interaction --no-progress"
)

# Commands run on the server (over SSH, cd'd into deployment_folder) before
# the sync. Nothing needed for Laravel.
pre_cmds_server=()

# Commands run on the server after the sync, in order. Each entry is
# arbitrary shell code (conditionals, loops, ...) run under bash; a failing
# command aborts the rest.
post_cmds_server=(
    # .env is always excluded from the sync, so the server needs its own.
    # Warn (remotely) when it is missing before running artisan. The warn
    # goes to stderr with the [deploy][warn] prefix, like local warnings.
    "if [ ! -f .env ]; then echo '[deploy][warn] no .env found on the server - artisan commands may fail' >&2; fi"
    "php artisan optimize"
)

# Commands run on the client after the deployment, in the source directory.
# Also run once when a step failed (exit trap), so configs that changed the
# local environment can restore it. Restore the development vendor/ the
# pre_cmds_client step replaced.
post_cmds_client=(
    "composer install --quiet --no-interaction --no-progress"
)
