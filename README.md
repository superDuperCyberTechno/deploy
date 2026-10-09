# deploy

Project-agnostic deployment script. Syncs any project (plain HTML up to
full web-apps, Laravel being the primary target) to a server with **rsync**
over SSH, using **SSH keys as the sole credential**, acting as the server
**root** user.

The target server does **not** need composer installed — installs run on
the client. The site is served through a **symlink** (`deployment_folder`)
that points at the currently active **snapshot folder**; every deploy
builds a fresh snapshot and switches the symlink atomically:

1. `deploy.sh` computes a local **snapshot id** from the git state (latest
   commit id plus every dirty file with its mtime).
2. It reads the server's active snapshot id (the `deployment_folder`
   symlink target) and skips with a message when it already matches — the
   source state is already live.
3. `pre_cmds_client` run locally, in the source directory, before the sync
   (e.g. `composer install --no-dev`), so the synced `vendor/` is
   production-ready; `pre_cmds_server` run on the server (in the currently
   active deployment).
4. The active snapshot is copied to a new snapshot folder
   `<project-name>-<snapshot id>` (first deploy: created empty) and the
   project is synced into it with `rsync -az --delete` (minus ignored
   files). Copying first carries server-side state into the new snapshot;
   shared state (see `Shared state` below) is never copied — each entry
   of the persistent `<name>-shared` home is symlinked into the snapshot
   instead, so `.env` and runtime data live once, outside the snapshots.
5. The web-server writable permission pass runs inside the new snapshot,
   then `post_cmds_server` (e.g. `php artisan optimize`).
6. The `deployment_folder` symlink is switched to the new snapshot — the
   last server-side step, so the switch is atomic — and old snapshots
   beyond `keep_snapshots` are pruned.
7. `post_cmds_client` run locally after the deployment (e.g. `composer
   install` to restore the dev environment). These also run — once — when
   any earlier step fails, so the local working copy is never left in a
   production state without development tooling.

## Requirements (local machine)

- `bash`, `rsync`, `ssh`, `openssh` client
- `git` (required: the snapshot id is derived from the repository state)
- `md5sum`, `stat` (coreutils, present on any mainstream distribution)
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
./extras/deploy/deploy.sh --rollback      # switch the live symlink back to the
                                          # newest earlier snapshot
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

## Snapshots and rollback

Every successful deploy leaves a snapshot folder
`<project-name>-<snapshot id>` next to the `deployment_folder` symlink and
makes the symlink point at the newest one. A snapshot is only ever built
for its exact source state (the already-live check prevents rebuilding the
active one), never modified in place afterwards.

Rollback switches the symlink back to the newest earlier snapshot, in one
command:

```bash
./deploy.sh --rollback
```

It does exactly one thing: the atomic symlink switch to the snapshot that
was serving right before the last deploy (deploy order, by snapshot
mtime). No sync, no command groups, no pruning — the snapshot's shared
state (`.env`, `storage`) lives in the `<name>-shared` home and is
symlinked, so it is identical across snapshots, and the next deploy
prunes old snapshots as usual. `--rollback` needs only the config
(`deployment_domain`, `ssh_key`, `deployment_folder`), not git or a
source directory. It aborts when there is no active deployment (first
deploy) or no earlier snapshot left.

Old snapshots are pruned after each successful deploy: the
`keep_snapshots` newest previous deployments (default `1`) are kept
alongside the active one, which is never pruned; `0` disables pruning.
A failed deploy leaves the symlink untouched — the previous snapshot
keeps serving — and the incomplete new snapshot is removed again.

## Shared state

Runtime state must never be copied between snapshots (a copy of a
live-written `storage` can be torn, and sessions written during a deploy
would be lost at the switch). Instead, everything the deployments share
lives in one persistent home on the server, `<deployment_folder>-shared`
(e.g. `/srv/myapp-shared`), and **every top-level entry of that home is
symlinked into each snapshot independently** — one symlink per entry, so
the entries stay usable in place (rsync-excluded, see below) and a
snapshot folder holds no copies of shared data at all.

`shared_links` entries may be nested: `shared_links=("folder1/folder2")`
shares exactly `folder2` across snapshots. The home mirrors the path as a
real directory tree (`<name>-shared/folder1/folder2`), the snapshot gets
one symlink at the same relative path, and the intermediate directory
(`folder1`) stays ordinary code in the snapshot. Structural directories
— ones that merely host a nested shared entry — are never linked
wholesale; content inside them must be listed in `shared_links` to be
shared.

`deploy.sh` manages this home automatically:

- `.env` is always shared this way: the first deploy after this feature
  moves the server's `.env` into the home, every snapshot links it.
- `shared_links` (config) lists additional entries to share (e.g.
  `shared_links=("storage")` for Laravel, or `("folder1/folder2")` for
  a nested one). The deploy migrates them into the home once (atomic
  move; the home copy is authoritative afterwards) and symlinks them
  into the snapshot at the same relative path.
- Anything else the administrator drops into the **top level** of the
  home — uploads, a sqlite file, sessions, a custom `uploads` dir — is
  symlinked automatically on the next deploy, no config change needed.

The migration happens in the build step, on the *new* snapshot's copy,
never on the live one, so the web server keeps serving uninterrupted
state until the atomic switch. The shared home is never pruned, never
synced, and survives rollback: every snapshot — current or rolled back
— serves the same `.env`, sessions and uploads.

To seed the home manually (no `shared_links` config), move the content on
the server once, e.g. `mv /srv/myapp/storage /srv/myapp-shared/storage`.

## Safety net

Before anything (including the command groups) runs, `deploy.sh` checks the
source directory for uncommitted git changes (`git status --porcelain`).
When it finds any, it lists them and waits for confirmation — press Enter
to continue, Ctrl+C to abort. `--dry-run` warns but never waits, and
non-terminal stdin (e.g. CI) continues without confirmation so automated
deployments do not hang. (The check always applies: git is required for
the snapshot id anyway.)

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
| `deployment_folder` | no | `/srv/<project-name>` | Symlink path of the live site on the server (what the web server serves); snapshot folders live next to it as `<name>-<snapshot id>` |
| `keep_snapshots` | no | `1` | Number of previous snapshots kept on the server after a deploy, alongside the active one (never pruned); `0` keeps all |
| `deployment_user` | no | (empty) | `user:group` assigned to every synced file via rsync `--chown` (e.g. `root:www-data`); empty keeps root ownership — without the web group the web server cannot read the `750` directories |
| `web_writable` | no | (empty) | Bash array of folders made group-writable over SSH (dirs `2770` with setgid, files `660`, no world access, ownership `deployment_user`) |
| `ignored` | no | (empty) | Bash array of additional rsync exclude patterns |
| `shared_links` | no | (empty) | Bash array of entries shared between snapshots via the persistent `<deployment_folder>-shared` home: each is migrated into the home once (move) and symlinked into every snapshot at the same relative path; nesting allowed (`folder1/folder2` shares exactly `folder2`, `folder1` stays code); `.env` is always handled this way; top-level entries already present in the home are linked too |
| `pre_cmds_client` | no | (empty) | Bash array of shell commands run on the client (working directory: the source project) before the sync |
| `pre_cmds_server` | no | (empty) | Bash array of shell commands run on the server (over SSH, in the currently active deployment) before the sync |
| `post_cmds_server` | no | (empty) | Bash array of shell commands run on the server (over SSH, in the new snapshot folder) after the sync; a failing command aborts the rest |
| `post_cmds_client` | no | (empty) | Bash array of shell commands run on the client after the deployment; also run once via an exit trap when a step failed, so the local environment can be restored |

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

Deployments follow a least-privilege model: root owns everything, the web
server reads via its group and writes only inside the `web_writable`
folders. Ownership and permissions are handled by the sync (rsync flags)
plus a dedicated remote permission pass that transfers nothing:

- `deployment_user` adds `--chown=user:group` to the main sync. Use
  `<owner>:<web-server-group>` (the boilerplate ships `root:www-data`): the
  owner keeps full control, the web server reads and traverses the code via
  the group. Empty keeps everything `root:root`, which a web server then
  cannot read (directories are `750`).
- The main sync applies `--chmod=Du=rwx,Dg=rx,Do=` — directories `750`
  (owner read/write/execute, group read/execute, no world access). File
  permission bits are preserved from the source, so executables (e.g.
  `artisan`) keep their `+x`.
- `web_writable` triggers a remote permission pass over SSH (`chown -R`
  when `deployment_user` is set, then `find ... chmod` per folder) — no
  file transfer happens, so ignored files can never leave the client, and
  permissions are applied unconditionally instead of depending on rsync's
  transfer decisions. The listed folders (e.g. Laravel's `storage` and
  `bootstrap/cache`) become group-writable with setgid: directories
  `2770`, files `660`, ownership `deployment_user`. The web server writes
  via the group while root keeps ownership; files and directories the web
  server creates inside inherit the group via setgid. It runs inside the
  new snapshot before `post_cmds_server`, so `php artisan optimize` can
  write `bootstrap/cache` right away — and before the symlink switch, so
  the live site is never affected.

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

- Because `.env` is always ignored, the server's `.env` is not synced
  either: the deploy migrates it once into the shared home
  (`<deployment_folder>-shared`) and every snapshot links it. The Laravel
  boilerplate checks for a missing `.env` before running its
  `post_cmds_server` group and warns; on a first deploy (no server
  `.env` anywhere yet, e.g. a fresh server) place it in the shared home
  and redeploy, or create it there.
- Every `shared_links` entry — and anything already in the shared home —
  is added to the rsync excludes **rooted at the top level** (e.g.
  `/storage`, and `/folder1/folder2` for a nested entry): rsync would
  otherwise replace the snapshot's symlink with a real directory, or
  sync through it into the shared home.
- Excluded paths are also protected from `rsync --delete`, so server-side
  data (uploads, sessions, logs, databases) is never wiped by a sync.
- The first connection may prompt to accept the server's host key.

## Exit codes

- `0` — deployment succeeded, or the source was already live (the deploy
  skipped with a message)
- `1` — configuration, tooling, rsync, or post-deployment failure (the
  local dev environment is restored before exiting)

## AI use

The majority of this codebase were written with the assistance of an AI coding
assistant.
