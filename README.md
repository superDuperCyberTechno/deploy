# deploy

Project-agnostic deployment script. Syncs any project (plain HTML up to
full web-apps, Laravel being the primary target) to a server with **rsync**
over SSH, using **SSH keys as the sole credential**, acting as the server
**root** user.

The target server does **not** need composer installed — installs run on
the client, driven by the config's four command groups:

1. `pre_cmds_client` run locally, in the source directory, before the sync
   (e.g. `composer install --no-dev`), so the synced `vendor/` is
   production-ready.
2. `pre_cmds_server` run on the server (over SSH) before the sync.
3. The project is synced with `rsync -az --delete` (minus ignored files).
4. `post_cmds_server` run on the server (e.g. `php artisan optimize`).
5. `post_cmds_client` run locally after the deployment (e.g. `composer
   install` to restore the dev environment). These also run — once — when
   any earlier step fails, so the local working copy is never left in a
   production state without development tooling.

## Requirements (local machine)

- `bash`, `rsync`, `ssh`, `openssh` client
- `git` (optional; only the uncommitted-changes safety net uses it)
- `composer` (only if the config's `pre_cmds_client` / `post_cmds_client`
  invoke it, as the Laravel boilerplate does)
- `curl` (only needed for `deploy.sh --init`, to download the boilerplate
  config from the public GitHub repository)
- Access to the server's root account via the configured SSH key

The server needs only an SSH server, a `bash` shell (the server command
groups run under it) and whatever the deployed app itself needs to run.

## Installation

Download the script to the current directory and make it executable:

```bash
curl -fsSL https://raw.githubusercontent.com/superDuperCyberTechno/deploy/main/deploy.sh -o ./deploy.sh && chmod +x ./deploy.sh
```

The download comes from the public GitHub repository
(`superDuperCyberTechno/deploy`, branch `main`). A failed download (e.g.
offline) aborts without creating or overwriting a file. Afterwards the
script can be run as `./deploy.sh` or moved anywhere on `$PATH` for
global use.

## Usage

```bash
./extras/deploy/deploy.sh --init            # fetch laravel boilerplate into ./deploy.conf.sh
./extras/deploy/deploy.sh --init laravel    # same, explicit boilerplate name
./extras/deploy/deploy.sh --init -c out.conf.sh  # write boilerplate to out.conf.sh
# edit deploy.conf.sh, then:
./extras/deploy/deploy.sh                 # deploy the current directory
./extras/deploy/deploy.sh ../some/path    # deploy another source directory
./extras/deploy/deploy.sh --dry-run       # preview the sync (no changes)
./extras/deploy/deploy.sh --verbose       # verbose rsync output
./extras/deploy/deploy.sh --version       # print the version
./extras/deploy/deploy.sh -c /etc/deploy.conf.sh   # custom config location
```

`deploy.sh --init [name]` does not generate the boilerplate inline: it
downloads `deploy.<name>.conf.sh` from the public GitHub repository
(`superDuperCyberTechno/deploy`, branch `main`) and writes it to
`./deploy.conf.sh` (overwrite with `--force`). The available boilerplate
names are hardcoded in the script (the `BOILERPLATES` array) and listed in
the help output; the matching `deploy.<name>.conf.sh` files are served from
the repository. To add a boilerplate, extend that array and commit its
`deploy.<name>.conf.sh` to the repository. A failed download (e.g. offline)
aborts with an error. The config location can also be set with the
`DEPLOY_CONF` environment variable or `-c PATH`.

## Safety net

Before anything (including the command groups) runs, `deploy.sh` checks the
source directory for uncommitted git changes (`git status --porcelain`).
When it finds any, it lists them and waits for confirmation — press Enter
to continue, Ctrl+C to abort. The check needs `git` installed and the
source inside a git work tree; it is skipped otherwise. `--dry-run` warns
but never waits, and non-terminal stdin (e.g. CI) continues without
confirmation so automated deployments do not hang.

## Versioning

`deploy.sh` follows [semantic versioning](https://semver.org): a `MAJOR`
bump for breaking changes (config keys, flags, behavior), `MINOR` for
backward-compatible additions, `PATCH` for backward-compatible fixes. The
current version is printed by `deploy.sh --version`.

## Configuration (`deploy.conf.sh`)

| Key | Required | Default | Purpose |
|-----|----------|---------|---------|
| `deployment_domain` | yes | — | Domain/IP to connect to over SSH as root |
| `ssh_key` | yes | — | Path to the SSH private key of the server root user |
| `deployment_folder` | no | `/srv/<project-name>` | Remote folder the project is synced into |
| `deployment_user` | no | (empty) | `user:group` assigned to every synced file via rsync `--chown` (e.g. `root:www-data`); empty keeps root ownership — without the web group the web server cannot read the `750` directories |
| `web_writable` | no | (empty) | Bash array of folders made group-writable via rsync `--chmod` (dirs `2770` with setgid, files `660`, no world access) |
| `ignored` | no | (empty) | Bash array of additional rsync exclude patterns |
| `pre_cmds_client` | no | (empty) | Bash array of shell commands run on the client (working directory: the source project) before the sync |
| `pre_cmds_server` | no | (empty) | Bash array of shell commands run on the server (over SSH, in `deployment_folder`) before the sync |
| `post_cmds_server` | no | (empty) | Bash array of shell commands run on the server (over SSH, in `deployment_folder`) after the sync; a failing command aborts the rest |
| `post_cmds_client` | no | (empty) | Bash array of shell commands run on the client after the deployment; also run once via an exit trap when a step failed, so the local environment can be restored |

Example:

```bash
deployment_domain="example.com"
ssh_key="$HOME/.ssh/id_ed25519"
deployment_folder="/srv/myapp"
deployment_user="root:www-data"
web_writable=(
    "storage"
    "bootstrap/cache"
)
ignored=(
    "storage/app/*"
    "storage/framework/cache/*"
)
pre_cmds_client=(
    "composer install --no-dev --optimize-autoloader"
)
post_cmds_server=(
    "php artisan optimize"
    "php artisan migrate --force"
)
post_cmds_client=(
    "composer install"
)
```

## File permissions

Deployments follow a least-privilege model: root owns everything, the web
server reads via its group and writes only inside the `web_writable`
folders. Ownership and permissions are handled with rsync flags only:

- `deployment_user` adds `--chown=user:group` to the main sync. Use
  `<owner>:<web-server-group>` (the boilerplate ships `root:www-data`): the
  owner keeps full control, the web server reads and traverses the code via
  the group. Empty keeps everything `root:root`, which a web server then
  cannot read (directories are `750`).
- The main sync applies `--chmod=Du=rwx,Dg=rx,Do=` — directories `750`
  (owner read/write/execute, group read/execute, no world access). File
  permission bits are preserved from the source, so executables (e.g.
  `artisan`) keep their `+x`.
- `web_writable` triggers a second, filter-restricted rsync pass with
  `--chmod` — necessary because a single rsync `--chmod` is global and
  cannot target specific paths. The listed folders (e.g. Laravel's
  `storage` and `bootstrap/cache`) become group-writable with setgid:
  directories `2770`, files `660`, group being `deployment_user`'s group.
  The web server writes via the group while root keeps ownership; files
  and directories the web server creates inside inherit the group via
  setgid. This pass runs before `post_cmds_server`, so `php artisan
  optimize` can write `bootstrap/cache` right away.

## Ignore handling

Every sync applies a **hardcoded, project-agnostic ignore list**:

```
.git/  .env  .env.*  node_modules/  .DS_Store  Thumbs.db
.phpunit.result.cache  .phpunit.cache
deploy.*.conf.sh
```

The **deploy toolchain** is never synced: the config files
(`deploy.*.conf.sh`), plus the script itself and the active config appended
by name at sync time, so a renamed script stays excluded as well.

The **Laravel defaults** live in the generated boilerplate config and cover
the storage/ internals (`storage/app/*`, `storage/framework/{cache,sessions,views}/*`,
`storage/logs/*`, `storage/*.key`), the sqlite database (`database/*.sqlite*`),
the compiled bootstrap cache (`bootstrap/cache/*`) and generated public
artifacts (`public/storage`, `public/hot`). Extend or replace them per
project in the `ignored` entry.

Notes:

- Because `.env` is always ignored, the server needs its own `.env` inside
  `deployment_folder`. The Laravel boilerplate checks for it before running
  its `post_cmds_server` group and warns when it is missing; non-Laravel
  projects add their own check to their config.
- Excluded paths are also protected from `rsync --delete`, so server-side
  data (uploads, sessions, logs, databases) is never wiped by a sync.
- The first connection may prompt to accept the server's host key.

## Exit codes

- `0` — deployment succeeded
- `1` — configuration, tooling, rsync, or post-deployment failure (the
  local dev environment is restored before exiting)