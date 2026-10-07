# deploy

Project-agnostic deployment script. Syncs any project (plain HTML up to
full web-apps, Laravel being the primary target) to a server with **rsync**
over SSH, using **SSH keys as the sole credential**, acting as the server
**root** user.

The target server does **not** need composer installed:

1. `composer install --no-dev` runs **locally** before the sync, so the
   synced `vendor/` is production-ready.
2. The project is synced with `rsync -az --delete` (minus ignored files).
3. `post_deployment_commands` run on the server (e.g. `php artisan optimize`).
4. `composer install` re-installs the development environment locally. This
   also happens when a step fails, so the local working copy is never left
   in a production state without development tooling.

## Requirements (local machine)

- `bash`, `rsync`, `ssh`, `openssh` client
- `composer` (only needed for the production install / dev restore steps;
  use `--no-composer` to skip)
- `curl` (only needed for `deploy --init`, to download the boilerplate
  config from the public GitHub repository)
- Access to the server's root account via the configured SSH key

The server needs only an SSH server and whatever the deployed app itself
needs to run.

## Usage

```bash
./extras/deploy/deploy --init            # fetch laravel boilerplate into ./deploy.conf
./extras/deploy/deploy --init laravel    # same, explicit boilerplate name
./extras/deploy/deploy --init -c out.conf  # write boilerplate to out.conf
# edit deploy.conf, then:
./extras/deploy/deploy                 # deploy the current directory
./extras/deploy/deploy ../some/path    # deploy another source directory
./extras/deploy/deploy --dry-run       # preview the sync (no changes)
./extras/deploy/deploy --verbose       # verbose rsync output
./extras/deploy/deploy --no-composer   # skip composer steps (sync vendor/ as-is)
./extras/deploy/deploy -c /etc/deploy.conf   # custom config location
```

`deploy --init [name]` does not generate the boilerplate inline: it
downloads `deploy.<name>.conf` from the public GitHub repository
(`superDuperCyberTechno/deploy`, branch `main`) and writes it to
`./deploy.conf` (overwrite with `--force`). The available boilerplate names
are hardcoded in the script (the `BOILERPLATES` array) and listed in the help
output; the matching `deploy.<name>.conf` files are served from the
repository. To add a boilerplate, extend that array and commit its
`deploy.<name>.conf` to the repository. A failed download (e.g. offline)
aborts with an error. The config location can also be set with the
`DEPLOY_CONF` environment variable or `-c PATH`.

## Configuration (`deploy.conf`)

| Key | Required | Default | Purpose |
|-----|----------|---------|---------|
| `deployment_domain` | yes | — | Domain/IP to connect to over SSH as root |
| `ssh_key` | yes | — | Path to the SSH private key of the server root user |
| `deployment_folder` | no | `/srv/<project-name>` | Remote folder the project is synced into |
| `deployment_user` | no | (empty) | `user:group` assigned to every synced file via rsync `--chown` (e.g. `www-data:www-data`); empty keeps local file ownership |
| `web_writable` | no | (empty) | Bash array of folders made writable by the web server via rsync `--chmod` (dirs `2775` with setgid, files `664`) |
| `ignored` | no | (empty) | Bash array of additional rsync exclude patterns |
| `post_deployment_commands` | no | (empty) | Bash array of commands run on the server after a successful sync |

Example:

```bash
deployment_domain="example.com"
ssh_key="$HOME/.ssh/id_ed25519"
deployment_folder="/srv/myapp"
deployment_user="www-data:www-data"
web_writable=(
    "storage"
    "bootstrap/cache"
)
ignored=(
    "storage/app/*"
    "storage/framework/cache/*"
)
post_deployment_commands=(
    "php artisan optimize"
    "php artisan migrate --force"
)
```

## File permissions

Ownership and permissions are handled with rsync flags only:

- `deployment_user` adds `--chown=user:group` to the main sync, so every
  transferred file is owned by the web server user instead of keeping the
  local developer's uid. Requires the sync over the server's root account,
  which this script assumes.
- `web_writable` triggers a second, filter-restricted rsync pass with
  `--chmod` — necessary because a single rsync `--chmod` is global and cannot
  target specific paths. The folders listed (e.g. Laravel's `storage` and
  `bootstrap/cache`) get directories `2775` with setgid and files `664`,
  group being `deployment_user`'s group, so the web server can write into
  them and files created later inherit the group via setgid. This pass runs
  before `post_deployment_commands`, so `php artisan optimize` can write
  `bootstrap/cache` right away.

## Ignore handling

Every sync applies a **hardcoded, project-agnostic ignore list**:

```
.git/  .env  .env.*  node_modules/  .DS_Store  Thumbs.db
.phpunit.result.cache  .phpunit.cache
```

The **Laravel defaults** live in the generated boilerplate config and cover
the storage/ internals (`storage/app/*`, `storage/framework/{cache,sessions,views}/*`,
`storage/logs/*`, `storage/*.key`), the sqlite database (`database/*.sqlite*`),
the compiled bootstrap cache (`bootstrap/cache/*`) and generated public
artifacts (`public/storage`, `public/hot`). Extend or replace them per
project in the `ignored` entry.

Notes:

- Because `.env` is always ignored, the server needs its own `.env` inside
  `deployment_folder`. The script warns when it cannot find one before
  running the post-deployment commands.
- Excluded paths are also protected from `rsync --delete`, so server-side
  data (uploads, sessions, logs, databases) is never wiped by a sync.
- The first connection may prompt to accept the server's host key.

## Exit codes

- `0` — deployment succeeded
- `1` — configuration, tooling, rsync, or post-deployment failure (the
  local dev environment is restored before exiting)