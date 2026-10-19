# TODO

Open security and usability issues, verified against `deploy.sh` 2.2.2.
Each entry lists location, problem and proposed fix.

## 1. No SSH host-key verification

- **Severity:** security
- **Location:** `deploy.sh:505` (`SSH_BASE_ARGS`)
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
- **Location:** `deploy.sh:331-351` (`--init` download), `deploy.sh:383`
  (`source "$CONF"`)
- **Problem:** `curl -fsSL` trusts whatever `raw.githubusercontent.com`
  returns at run time; the file is then executed as shell by `source`.
  No checksum, signature, tag pinning or script/config version check
  exists, so a compromised upstream or branch gains local code execution.
- **Fix:** Pin downloads to a release tag or commit, publish and verify a
  SHA-256 checksum (and optionally a signature) before writing, and abort
  on mismatch. Keep `main` behind an explicit opt-in flag.

## 3. GNU-only tooling limits client and server portability

- **Severity:** usability
- **Location:** `deploy.sh:201` (`readlink -f`), `deploy.sh:254`,
  `deploy.sh:544`, `deploy.sh:547`, `deploy.sh:932` (`stat -c`),
  `deploy.sh:258` (`md5sum`)
- **Problem:** `readlink -f`, GNU `stat -c` and `md5sum` are assumed on
  both ends. macOS/BSD clients fail on snapshot hashing, and remote hosts
  without GNU coreutils fail on symlink resolution, mtime ordering and
  rollback selection. Errors surface late, after SSH work started.
- **Fix:** Add preflight tool check for client and server, with
  `shasum`/`sha256sum` fallback, avoid `readlink -f` (use `realpath` or
  `readlink` loop), and use portable `stat` wrappers. Fail early with
  clear message.

## 4. `--rollback` switches live site without confirmation or target list

- **Severity:** usability / operational safety
- **Location:** `deploy.sh:518-577`
- **Problem:** `--rollback` picks the newest earlier snapshot and switches
  the live symlink immediately. It prints only the chosen target and does
  not list the available snapshots. `--dry-run` reports the target, but
  there is no interactive confirmation, so mistyped or scripted call can
  serve older release without warning.
- **Fix:** List candidate snapshots (active plus available rollback
  targets) before switching, prompt for confirmation when stdin is a
  terminal, and require `--force` (or `--dry-run`) in non-interactive
  contexts.

## Completed

- Validated `deployment_folder` as normalized absolute path (rejects `/`,
  relative paths, `.`/`..` and control characters) and require an existing
  server-side parent before snapshot build. Version 2.2.2.
