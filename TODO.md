# TODO

Open security and usability issues, verified against `deploy.sh` 4.0.1.
Each entry lists location, problem and proposed fix.

## 1. No SSH host-key verification

- **Severity:** security
- **Location:** `deploy.sh`, `SSH_BASE_ARGS`
- **Problem:** Only `BatchMode` and `ConnectTimeout` are set. Host key
  checking is left to the user's SSH config. A first connection to an
  unknown host either fails opaquely or, with `accept-new`, can be
  hijacked; `UserKnownHostsFile`/`StrictHostKeyChecking` are not pinned.
  Combined with root-only login, wrong or spoofed host gets full
  deployment access.
- **Fix:** Set explicit `StrictHostKeyChecking=accept-new` (or `yes`) and
  known-hosts file by default, expose opt-out config key, and document
  host-key pinning for new servers.

## 2. Boilerplate config fetched and sourced without integrity check

- **Severity:** security
- **Location:** `deploy.sh`, `--init` download and `source "$CONF"`
- **Problem:** `curl -fsSL` trusts whatever `raw.githubusercontent.com`
  returns at run time; the file is then executed as shell by `source`.
  No checksum, signature, tag pinning or script/config version check
  exists, so a compromised upstream or branch gains local code execution.
- **Fix:** Pin downloads to a release tag or commit, publish and verify a
  SHA-256 checksum (and optionally a signature) before writing, and abort
  on mismatch. Keep `main` behind an explicit opt-in flag.

## Completed

- Removed snapshots, deployment symlinks, rollback, `keep_snapshots`, and
  the shared home. Deployments now sync directly into `deployment_folder`;
  rollback is git checkout plus redeploy. Version 4.0.0.
- Replaced `shared_links` with `preserved`. Preserved paths are excluded
  from rsync and bootstrapped empty on first deploy. Version 4.0.0.
- Removed GNU-only snapshot hashing and symlink resolution (`md5sum`,
  `stat -c`, `readlink -f`). Version 4.0.0.
