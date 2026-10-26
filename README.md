# deploy 4.0.0

Project-agnostic deployment script: syncs any project directly into a
server folder with **rsync** over SSH, using **SSH keys only** and acting
as **root**. The server does not need composer; installs run on the
client.

There are no snapshots, no deployment symlinks, and no shared home. The
web server serves the deployment folder as a normal directory. Runtime
state is kept server-side by excluding `preserved` paths from rsync.

Rollback is done with git and a second deployment: restore the previous
source state locally, then deploy again.

## Flow

1. Run `pre_cmds_client` locally in the source directory (e.g. `composer
   install --no-dev`).
2. Prepare the deployment folder on the server. The folder is created
   when missing; missing `preserved` directories and files are
   bootstrapped.
3. Run `pre_cmds_server` on the server in the deployment folder. The
   Laravel boilerplate enables maintenance mode here when `artisan`
   already exists.
4. Sync the project into the deployment folder with `rsync -az
   --delete-after --delay-updates`. Ignored and `preserved` paths are
   excluded, so server-owned data is never overwritten or deleted.
5. Run the writable permission pass, then `post_cmds_server` (e.g. `php
   artisan optimize`). The Laravel boilerplate disables maintenance mode
   when the post-sync command group exits.
6. Run `post_cmds_client` locally (e.g. `composer install`) to restore the
   dev environment. It also runs once if an earlier step fails.

## Rsync update timing

**`--delay-updates` and `--delete-after` reduce the mixed old/new code window but do not make deployment atomic.**

- `--delay-updates` transfers updated files under temporary names and
  renames them into place at the end, instead of updating files one by one
  during transfer.
- `--delete-after` removes destination files that are absent from the
  source only after the transfer, so old workers keep their files longer.
- Both increase peak disk usage: old files remain and updated files need
  temporary space until the final renames.
- Requests can still observe mixed old/new files during the final rename
  and delete phase, and `post_cmds_server` runs after the sync. Use
  maintenance mode or a staged/atomic switch when downtime is not
  acceptable.

## Laravel maintenance mode

**The Laravel boilerplate enables maintenance mode before rsync and disables it after the post-sync server commands.**

- `pre_cmds_server` runs `php artisan down` when `artisan` exists.
- `post_cmds_server` starts with `trap 'php artisan up' EXIT`, so
  maintenance mode is disabled when the remote command group exits,
  including when `queue:restart`, `schedule:clear-cache`, or `optimize`
  fails.
- On a fresh deployment folder there is no `artisan` yet, so maintenance
  mode is skipped. Nothing is being served from that folder until the
  first sync finishes.
- If rsync itself fails, `post_cmds_server` never runs. The site stays in
  maintenance mode until `php artisan up` is run manually.

## Requirements (local machine)

**The client needs basic Unix tools and root SSH access; the server needs only SSH, bash, and the app's own runtime.**

- `bash`, `rsync`, `ssh`, `openssh` client
- `curl` (only for `deploy.sh --init`)
- `git` (optional: only for the uncommitted-changes warning)
- `composer` (only if the configured client commands use it)
- Access to the server's root account via the configured SSH key

The server needs an SSH server, a `bash` shell, and whatever the app needs.

## Installation and updates

**Download the script, make it executable, then run it directly or from `$PATH`.**

The following command can be run to update the script as well.

```bash
curl -fsSL https://raw.githubusercontent.com/superDuperCyberTechno/deploy/main/deploy.sh -o ./deploy.sh && chmod +x ./deploy.sh
```

The download comes from the public GitHub repository
(`superDuperCyberTechno/deploy`, branch `main`). A failed download aborts
without creating or overwriting a file.

## Usage

**Initialize a config, edit it, then deploy; flags cover preview and custom config paths.**

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

`--init [name]` downloads `deploy.<name>.conf.sh` from the public GitHub
repository to `./deploy.conf.sh` (use `--force` to overwrite). Boilerplate
names are hardcoded in the `BOILERPLATES` array and listed in the help
output. To add one, extend that array and commit its config file. A failed
download aborts. The config path can also come from `DEPLOY_CONF` or
`-c PATH`.

## Deployment folder

**The deployment folder is a real directory synced in place; the parent must exist on the server.**

`deployment_folder` defaults to `/srv/<project-name>`. It must be an
absolute path below `/`, without `.` or `..` components or control
characters. The parent folder must already exist, so a typo cannot move
the deployment elsewhere.

The script creates the deployment folder when missing. It must be a real
directory: symlinks are rejected because rsync would write through them
into the link target. Deploy to fresh folders; no 3.x layout migration is
performed.

## Preserved server state

**`preserved` lists server-owned paths that rsync must never write into or delete.**

Typical Laravel entries:

```bash
preserved=(
    "storage"
    ".env"
    "database/database.sqlite"
)
```

Preserved entries may be nested (`database/database.sqlite`) and are added
to the rsync ignore list as rooted patterns (`/database/database.sqlite`).
They are also excluded from `rsync --delete`, so uploads, sessions, logs,
secrets, and database contents survive every deployment.

First-deploy bootstrap:

- A missing preserved entry that is a directory in the source is recreated
  with its source subfolder tree, empty. No files are copied.
- A missing preserved entry that is a file, or absent from the source, is
  created empty.
- An existing preserved directory, file, or symlink is never modified.

The server copy is authoritative after bootstrap. `.env` for Laravel is
therefore created empty on first deploy; fill it in on the server.

## Web server and OPcache

**A real deployment directory avoids PHP-FPM symlink-path caching; normal OPcache revalidation settings apply.**

Keep normal production OPcache settings (for example
`opcache.validate_timestamps=0` and reload PHP-FPM after deploying when
opcache is disabled from revalidating).

## Safety net

**Uncommitted git changes are listed and require confirmation before any deploy step runs.**

When git is installed and the source is a work tree, `deploy.sh` checks
`git status --porcelain`. It lists changes and waits for Enter; Ctrl+C
aborts. `--dry-run` warns but does not wait. Non-terminal stdin (e.g. CI)
continues without confirmation so automated deploys do not hang. Deploying
without git is supported.

## Versioning

**`deploy.sh` uses [semantic versioning](https://semver.org): `MAJOR`.`MINOR`.`PATCH`**

`MAJOR` for breaking changes, `MINOR` for backward-compatible additions, `PATCH` for
backward-compatible fixes. `deploy.sh --version` prints the version.

## Configuration (`deploy.conf.sh`)

**The config file sets connection, preservation, permission, and command options; only `deployment_domain` and `ssh_key` are required.**

| Key | Required | Default | Purpose |
|-----|----------|---------|---------|
| `deployment_domain` | yes | - | Domain/IP to connect to over SSH as root |
| `ssh_key` | yes | - | Path to the server root user's SSH private key |
| `deployment_folder` | no | `/srv/<project-name>` | Absolute path of the live directory; parent must exist on server |
| `deployment_user` | no | (empty) | `user:group` applied via rsync `--chown` (e.g. `root:www-data`); empty keeps root ownership |
| `web_writable` | no | (empty) | Folders made group-writable over SSH (dirs `2770` with setgid, files `660`, no world access) |
| `ignored` | no | (empty) | Additional rsync exclude patterns |
| `preserved` | no | (empty) | Server-owned paths rsync never touches; missing dirs/files are bootstrapped empty; nesting allowed |
| `pre_cmds_client` | no | (empty) | Commands run on the client in the source project before sync |
| `pre_cmds_server` | no | (empty) | Commands run on the server in the deployment folder before sync |
| `post_cmds_server` | no | (empty) | Commands run on the server in the deployment folder after sync; failure aborts the rest |
| `post_cmds_client` | no | (empty) | Commands run on the client after deploy; also run once via exit trap if a step fails |

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
    "public/storage"
    "public/hot"
)
preserved=(
    "storage"
    ".env"
    "database/database.sqlite"
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

**Root owns everything, the web server reads via its group, and writes only inside `web_writable` folders.**

- `deployment_user` adds `--chown=user:group` to the main sync. Use
  `<owner>:<web-server-group>` (the boilerplate ships `root:www-data`).
  Empty keeps `root:root`, which a web server cannot read because
  directories are `750`.
- The main sync applies `--chmod=Du=rwx,Dg=rx,Do=` - directories are `750`.
  File permission bits come from the source, so executables such as
  `artisan` keep `+x`.
- `web_writable` runs a remote permission pass over SSH (`chown -R` when
  `deployment_user` is set, then `find ... chmod` per folder). No files are
  transferred. Listed folders (e.g. `storage`, `bootstrap/cache`,
  `database`) become group-writable with setgid: directories `2770`, files
  `660`, owner `deployment_user`. The web server writes through the group,
  and new files inherit the group via setgid. It runs after the sync and
  before `post_cmds_server`.
- `web_writable` does not define preservation. A writable path that must
  survive deploys (such as the shared SQLite database file) also belongs in
  `preserved`.

## Ignore handling

**A hardcoded ignore list always applies; config adds project-specific excludes, and preserved entries are protected from writes and deletion.**

Every sync applies this **hardcoded, project-agnostic ignore list**:

```
.git/  .env  .env.*  node_modules/  .DS_Store  Thumbs.db
.phpunit.result.cache  .phpunit.cache
deploy.*.conf.sh
```

The deploy toolchain is never synced: config files (`deploy.*.conf.sh`),
the script itself, and the active config appended by name, so a renamed
script stays excluded.

The Laravel defaults live in the generated boilerplate config. The script
adds every `preserved` entry as a rooted exclude and excludes it from
`--delete`. The boilerplate's `ignored` covers sqlite journal sidecars
(`database/*.sqlite*`), compiled bootstrap cache (`bootstrap/cache/*`), and
generated public files (`public/storage`, `public/hot`). Its `preserved`
keeps `storage`, `.env`, and `database/database.sqlite`. Extend or replace
these per project.

Notes:

- `.env` is never synced: base ignore list excludes `.env` and `.env.*`.
  Laravel boilerplate also lists `.env` in `preserved`, so first deploy
  creates it empty in the deployment folder; fill it in on the server.
- Excluded paths are protected from `rsync --delete`, so server-side data
  (uploads, sessions, logs, databases) is never wiped.
- The first connection may ask to accept the server's host key.

## Exit codes

**`0` means success; `1` means a configuration, tooling, rsync, or post-deployment failure.**

- `0` - deployment succeeded
- `1` - configuration, tooling, rsync, or post-deployment failure (the local
  dev environment is restored before exiting)

## AI use

The majority of this codebase was written with the assistance of an AI
coding assistant.
