# deploy

Project-agnostic deployment script: syncs any project to a server with
**rsync** over SSH, using **SSH keys only** and acting as **root**. The
server does not need composer; installs run on the client.

The live site is a **symlink** (`deployment_folder`) to the current
**snapshot folder**. Each deploy builds a new snapshot and switches the
symlink atomically:

1. Build a local **snapshot id** from the git state (latest commit id plus
   every dirty file and its mtime).
2. Read the server's active snapshot id and skip if it matches - the source
   is already live.
3. Run `pre_cmds_client` locally in the source directory (e.g. `composer
   install --no-dev`) and `pre_cmds_server` on the server in the active
   deployment.
4. Copy the active snapshot to `<project-name>-<snapshot id>` (first
   deploy: empty) and sync the project into it with `rsync -az --delete`.
   The copy carries server-side state forward. Shared state (see below) is
   never copied; each entry in `<name>-shared` is symlinked instead.
5. Run the writable permission pass in the new snapshot, then
   `post_cmds_server` (e.g. `php artisan optimize`).
6. Switch the `deployment_folder` symlink to the new snapshot (the last
   server-side step, so it is atomic) and prune old snapshots.
7. Run `post_cmds_client` locally (e.g. `composer install`) to restore the
   dev environment. It also runs once if an earlier step fails.

## Requirements (local machine)

### The client needs basic Unix tools, git, and root SSH access; the server needs only SSH, bash, and the app's own runtime.

- `bash`, `rsync`, `ssh`, `openssh` client
- `git` (the snapshot id comes from the repository state)
- `md5sum`, `stat` (coreutils)
- `composer` (only if the configured client commands use it)
- `curl` (only for `deploy.sh --init`)
- Access to the server's root account via the configured SSH key

The server needs an SSH server, a `bash` shell, and whatever the app needs.

## Installation and updates

### Download the script, make it executable, then run it directly or from `$PATH`.

The following command can be run to update the script as well.

```bash
curl -fsSL https://raw.githubusercontent.com/superDuperCyberTechno/deploy/main/deploy.sh -o ./deploy.sh && chmod +x ./deploy.sh
```

The download comes from the public GitHub repository
(`superDuperCyberTechno/deploy`, branch `main`). A failed download aborts
without creating or overwriting a file.

## Usage

### Initialize a config, edit it, then deploy; flags cover preview, rollback, and custom config paths.

```bash
./extras/deploy/deploy.sh --init            # fetch laravel boilerplate into ./deploy.conf.sh
./extras/deploy/deploy.sh --init laravel    # same, explicit boilerplate name
./extras/deploy/deploy.sh --init -c out.conf.sh  # write boilerplate to out.conf.sh
# edit deploy.conf.sh, then:
./extras/deploy/deploy.sh                 # deploy the current directory
./extras/deploy/deploy.sh ../some/path    # deploy another source directory
./extras/deploy/deploy.sh --dry-run       # preview the sync (no changes)
./extras/deploy/deploy.sh --verbose       # verbose rsync output
./extras/deploy/deploy.sh --rollback      # switch the live symlink back to the
                                          # newest earlier snapshot
./extras/deploy/deploy.sh --version       # print the version
./extras/deploy/deploy.sh -c /etc/deploy.conf.sh   # custom config location
```

`--init [name]` downloads `deploy.<name>.conf.sh` from the public GitHub
repository to `./deploy.conf.sh` (use `--force` to overwrite). Boilerplate
names are hardcoded in the `BOILERPLATES` array and listed in the help
output. To add one, extend that array and commit its config file. A failed
download aborts. The config path can also come from `DEPLOY_CONF` or
`-c PATH`.

## Snapshots and rollback

### Each deploy creates one immutable snapshot and points the live symlink at it; rollback switches back to the previous one.

A snapshot folder `<project-name>-<snapshot id>` sits next to the
`deployment_folder` symlink. It is built only for its exact source state
(the already-live check prevents rebuilding the active one) and is never
changed in place.

Rollback switches the symlink back to the snapshot that served before the
last deploy:

```bash
./deploy.sh --rollback
```

It does only the atomic symlink switch (deploy order, by snapshot mtime).
No sync, commands, or pruning. Shared state (`.env`, `storage`) lives in
the `<name>-shared` home, so it is the same across snapshots. `--rollback`
needs only `deployment_domain`, `ssh_key`, and `deployment_folder` - no git
or source directory. It aborts if there is no active deployment or no
earlier snapshot.

After each successful deploy, the `keep_snapshots` newest previous
deployments (default `1`) are kept beside the active one; `0` disables
pruning. A failed deploy leaves the symlink untouched and removes the
incomplete snapshot.

## Shared state

### Runtime data lives once in `<deployment_folder>-shared` and is symlinked into every snapshot, never copied.

Copying a live-written `storage` can tear files, and sessions written
during a deploy would be lost at the switch. Instead, every top-level entry
of the shared home (e.g. `/srv/myapp-shared`) is symlinked into each
snapshot independently. Entries stay in place, are excluded from rsync,
and are never duplicated into snapshots.

`shared_links` entries may be nested: `shared_links=("folder1/folder2")`
shares exactly `folder2`. The home mirrors the path
(`<name>-shared/folder1/folder2`), and the snapshot gets one symlink at the
same path. The intermediate `folder1` stays ordinary code. Content inside
structural directories must be listed in `shared_links` to be shared.

`deploy.sh` manages the shared folder automatically:

- `.env` is always shared: the first deploy moves the server's `.env` into
  the home, and every snapshot links it.
- `shared_links` lists additional entries (e.g. `("storage")` or
  `("folder1/folder2")`). Each is moved into the shared folder once (atomic; the
  shared copy is authoritative) and symlinked into the snapshot at the same
  path.
- Anything else dropped into the **top level** of the shared folder (uploads, a
  sqlite file, sessions, a custom `uploads` dir) is linked on the next
  deploy without config changes.

Migration happens on the new snapshot's copy, never on the live one, so the
web server keeps serving until the atomic switch. The shared home is never
pruned or synced and survives rollback.

To seed the home manually, move content on the server once, e.g.
`mv /srv/myapp/storage /srv/myapp-shared/storage`.

## Web server: symlink and OPcache caveat

### PHP can cache the resolved symlink path, so the old snapshot may keep serving until PHP-FPM reloads; make the web server pass the resolved path instead ([Deployer docs](https://deployer.org/docs/8.x/avoid-php-fpm-reloading)).

- **Nginx**: use `$realpath_root` for `SCRIPT_FILENAME` and `DOCUMENT_ROOT`.
- **Caddy**: enable `resolve_root_symlink`.
- **Apache**: set `opcache.revalidate_path=1`.

## Safety net

### Uncommitted git changes are listed and require confirmation before any deploy step runs.

`deploy.sh` checks `git status --porcelain` first, including before command
groups. It lists changes and waits for Enter; Ctrl+C aborts. `--dry-run`
warns but does not wait. Non-terminal stdin (e.g. CI) continues without
confirmation so automated deploys do not hang. The check always applies
because git is needed for the snapshot id.

## Versioning

### `deploy.sh` uses [semantic versioning](https://semver.org): `MAJOR`.`MINOR`.`PATCH`

`MAJOR` for breaking changes, `MINOR` for backward-compatible additions, `PATCH` for
backward-compatible fixes. `deploy.sh --version` prints the version.

## Configuration (`deploy.conf.sh`)

### The config file sets connection, snapshot, sharing, and command options; only `deployment_domain` and `ssh_key` are required.

| Key | Required | Default | Purpose |
|-----|----------|---------|---------|
| `deployment_domain` | yes | - | Domain/IP to connect to over SSH as root |
| `ssh_key` | yes | - | Path to the server root user's SSH private key |
| `deployment_folder` | no | `/srv/<project-name>` | Symlink path of the live site; snapshots sit next to it |
| `keep_snapshots` | no | `1` | Previous snapshots kept beside the active one; `0` keeps all |
| `deployment_user` | no | (empty) | `user:group` applied via rsync `--chown` (e.g. `root:www-data`); empty keeps root ownership |
| `web_writable` | no | (empty) | Folders made group-writable over SSH (dirs `2770` with setgid, files `660`, no world access) |
| `ignored` | no | (empty) | Additional rsync exclude patterns |
| `shared_links` | no | (empty) | Entries shared via `<deployment_folder>-shared`: moved into the home once, then symlinked into every snapshot; nesting allowed; `.env` is always shared |
| `pre_cmds_client` | no | (empty) | Commands run on the client in the source project before sync |
| `pre_cmds_server` | no | (empty) | Commands run on the server in the active deployment before sync |
| `post_cmds_server` | no | (empty) | Commands run on the server in the new snapshot after sync; failure aborts the rest |
| `post_cmds_client` | no | (empty) | Commands run on the client after deploy; also run once via exit trap if a step fails |

Example:

```bash
deployment_domain="example.com"
ssh_key="$HOME/.ssh/id_ed25519"
deployment_folder="/srv/myapp"
keep_snapshots=5
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

### Root owns everything, the web server reads via its group, and writes only inside `web_writable` folders.

- `deployment_user` adds `--chown=user:group` to the main sync. Use
  `<owner>:<web-server-group>` (the boilerplate ships `root:www-data`).
  Empty keeps `root:root`, which a web server cannot read because
  directories are `750`.
- The main sync applies `--chmod=Du=rwx,Dg=rx,Do=` - directories are `750`.
  File permission bits come from the source, so executables such as
  `artisan` keep `+x`.
- `web_writable` runs a remote permission pass over SSH (`chown -R` when
  `deployment_user` is set, then `find ... chmod` per folder). No files are
  transferred. Listed folders (e.g. `storage`, `bootstrap/cache`) become
  group-writable with setgid: directories `2770`, files `660`, owner
  `deployment_user`. The web server writes through the group, and new files
  inherit the group via setgid. It runs in the new snapshot before
  `post_cmds_server`, and before the symlink switch, so the live site is
  never affected.

## Ignore handling

### A hardcoded ignore list always applies; config adds project-specific excludes, and shared entries are excluded so rsync never replaces their symlinks.

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
excludes every top-level `shared_links` entry (`/storage`) before syncing.
The boilerplate's `ignored` covers sqlite journal sidecars
(`database/*.sqlite*`), compiled bootstrap cache (`bootstrap/cache/*`), and
generated public files (`public/storage`, `public/hot`). Its `shared_links`
shares `storage` and `database/database.sqlite`. Extend or replace these
per project.

Notes:

- `.env` is always ignored and never synced. The deploy moves the server's
  `.env` into the shared home once, and every snapshot links it. The
  Laravel boilerplate warns if `.env` is missing before `post_cmds_server`.
  On a fresh server, place `.env` in the shared home and redeploy, or create
  it there.
- Every `shared_links` entry, and anything already in the shared home, is
  excluded **rooted at the top level** (`/storage`, `/folder1/folder2`).
  Otherwise rsync would replace the snapshot's symlink with a real
  directory or sync through it into the shared home.
- Excluded paths are protected from `rsync --delete`, so server-side data
  (uploads, sessions, logs, databases) is never wiped.
- The first connection may ask to accept the server's host key.

## Exit codes

### `0` means success or an already-live source; `1` means a configuration, tooling, rsync, or post-deployment failure.

- `0` - deployment succeeded, or the source was already live (skipped)
- `1` - configuration, tooling, rsync, or post-deployment failure (the local
  dev environment is restored before exiting)

## AI use

The majority of this codebase was written with the assistance of an AI
coding assistant.
