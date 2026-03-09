# Design: Nix-Managed Bazel Module Precacher (v2)

## Context

Building Redpanda via `nix build` requires running Bazel inside Nix's sandbox, where
there is no network access. The previous approach used a Fixed-Output Derivation (FOD)
to run `bazel fetch` with network access, downloading ~470 archives. This was fragile:
the FOD hash is all-or-nothing (any MODULE.bazel change invalidates everything).

This document describes the **implemented** replacement: per-archive Nix `fetchurl`
derivations assembled into a linkFarm that serves as Bazel's repository cache.

## The Core Problem

Bazel modules need three things to work in Nix's sandbox:
1. **Downloaded** — no network in sandbox
2. **Nixified** — ELF binaries need patched interpreters/rpath, scripts need
   Nix-compatible shebangs, some modules need custom patches
3. **Provided to Bazel** — in a format Bazel recognizes

The challenge: Bazel's repository cache is **content-addressed by sha256**. Modifying
an archive changes its hash, so Bazel can't find it. Nixification MUST happen after
Bazel extracts the archives, not before.

## Two-Derivation Architecture

```
  ┌─────────────────────────────────────────────────────────┐
  │  Inputs: MODULE.bazel.lock, BCR source.json, MODULE.bazel│
  └───────────────────────┬─────────────────────────────────┘
                          │
                ┌─────────▼─────────┐
                │ gen-bazel-deps.py  │  (run manually when deps change)
                │ Parses all sources │
                │ Outputs bazel-deps.nix
                └─────────┬─────────┘
                          │
  ════════════════════════╪════════════════════════════════════
  Derivation 1: Download  │  (linkFarm — instant rebuild, per-archive caching)
  ════════════════════════╪════════════════════════════════════
                          │
                ┌─────────▼──────────────────┐
                │  bazel-repo-cache.nix       │
                │                            │
                │  For each { url, sha256 }: │
                │    fetchurl { ... }         │
                │                            │
                │  linkFarm layout:           │
                │    content_addressable/     │
                │      sha256/<hex>/file →    │
                │        /nix/store/<hash>    │
                └─────────┬──────────────────┘
                          │
  ════════════════════════╪════════════════════════════════════
  Derivation 2: Build     │  (single derivation, NO network, NO FOD)
  ════════════════════════╪════════════════════════════════════
                          │
                ┌─────────▼──────────────────────────────────┐
                │  redpanda.nix                              │
                │                                            │
                │  Step A: bazel fetch                       │
                │    --repository_cache=<linkFarm>            │
                │    --repository_disable_download            │
                │    (extracts archives, runs repo rules)     │
                │    (may fail — ELF binaries can't execute)  │
                │                                            │
                │  Step B: NIXIFY PIPELINE                   │
                │    Apply configurable fixups to             │
                │    extracted repos in output_base/external/ │
                │    - patchelf (ELF interpreter + rpath)     │
                │    - fix-shebangs (#!/bin/bash → nix bash)  │
                │    - per-module patches (if needed)         │
                │                                            │
                │  Step C: bazel fetch (retry)               │
                │    Now succeeds — patched binaries work     │
                │    (repeat B+C if needed)                  │
                │                                            │
                │  Step D: bazel build                       │
                │    Uses nixified extracted repos            │
                └────────────────────────────────────────────┘
```

## Why Only 2 Derivations (Not 3)?

It's tempting to separate "Extract + Nixify" into its own derivation for caching.
But Bazel's `output_base/external/` directory is **not portable**:
- The output_base path is derived from MD5(workspace_root_path)
- Marker files (`.marker`) encode internal state
- Transplanting extracted repos between output_bases is unsupported

So extract + nixify + build must happen in the same derivation. This is fine —
the expensive part is the C++ compilation, not the fetch+nixify (~minutes).

## Why `fetchurl` (Not `fetchFromGitHub`) for Repo Cache

Bazel's repo cache is content-addressed: it computes sha256 of the raw archive
bytes and looks up `content_addressable/sha256/<hex>/file`. The hash in the
lockfile matches the raw tarball download.

`fetchFromGitHub` (which uses `fetchzip` internally) produces an **unpacked,
normalized** source tree with a completely different NAR hash. The raw tarball
bytes are discarded. So `fetchFromGitHub` output cannot be placed in the repo
cache — Bazel would never find it.

**Where we DO use `fetchFromGitHub`:**
- BCR snapshot (`nix/bcr.nix`) — Bazel reads via `--registry=file://`
- `rules_python` fork — provided via `local_path_override` in MODULE.bazel

**Where we MUST use `fetchurl`:**
- All repo cache entries (254 archives) — Bazel needs exact tarball bytes

## Nixify Pipeline Design

The pipeline is a configurable list of fixup rules applied to extracted repos
after `bazel fetch`. Defined in `nix/nixify-rules.nix`:

```nix
nixifyRules = [
  {
    type = "patchelf";
    interpreter = "${glibc}/lib/ld-linux-x86-64.so.2";
    rpath = "${glibc}/lib:${gcc-unwrapped.lib}/lib:...";
  }
  {
    type = "fix-shebangs";
    from = "/bin/bash";
    to = "${bash}/bin/bash";
  }
  # Per-module patches can be added:
  # { type = "patch"; module = "rules_cc"; patches = [ ... ]; }
  # { type = "substitute"; module = "..."; file = "..."; from = "..."; to = "..."; }
];
```

The `bazel-sandbox-patcher` script processes these rules:
- `patchelf` — walks all files, finds ELF binaries, patches interpreter+rpath
- `fix-shebangs` — finds scripts with matching shebangs, rewrites them

These rules live in a dedicated file, separate from the build logic. This makes
it easy to add/review fixups without touching build configuration.

## Generator Script (`gen-bazel-deps.py`)

Parses three sources to build the complete archive list:

1. **BCR `source.json` files** — for each source.json URL in the lockfile's
   `registryFileHashes`, read the corresponding file from the local BCR.
   Extract `url` + `integrity` (SRI format → convert to hex).

2. **`moduleExtensions.*.generatedRepoSpecs`** in lockfile — for repos with
   `url`/`urls` AND `sha256`/`integrity` attributes.
   Handles dict-valued urls/sha256 (toolchains_llvm per-platform entries).

3. **`archive_override` and top-level `http_file`/`http_archive` entries**
   in `MODULE.bazel` — extract URL + integrity directly from Starlark source.

**Does NOT cache:**
- BCR registry files (~280 MODULE.bazel/source.json) — served by local BCR
  via `--registry=file://`, no download needed
- Repos without URLs (local_repository, configure rules, etc.)
- OCI image pulls (different download mechanism)

## Key Design Decisions

### 1. Use `--repository_cache` (not `--distdir`)
- `--distdir` matches by filename then verifies hash — fragile
- `--repository_cache` is pure content-addressed lookup by hash

### 2. Disable canonical IDs
`BAZEL_HTTP_RULES_URLS_AS_DEFAULT_CANONICAL_ID=0` — makes the cache purely
content-addressed, matching Bazel's own bootstrap approach.

### 3. Use `linkFarm` for independent per-archive caching
Each archive is a separate `fetchurl` derivation. Adding/removing one doesn't
invalidate others. The linkFarm creates symlinks — trivial rebuild.

### 4. Hash format: hex sha256
Everything normalized to hex for cache paths. SRI from BCR converted via
`base64.b64decode().hex()`.

## Resolved Questions

**Q: Registry files — cache them?**
A: No. With `--registry=file://<local-bcr>`, Bazel reads registry files
directly from the filesystem. Only module archives need caching.

**Q: Can patchelf happen in the download phase?**
A: No. Modifying archives changes their hash, breaking content-addressed lookup.

**Q: Why not a separate "nixify" derivation?**
A: Bazel's output_base is not portable between workspace paths.

**Q: Does `--repository_disable_download` prevent all network access?**
A: It disables `repository_ctx.download()`. Combined with Nix's sandbox,
this is belt-and-suspenders.

## Files

| File | Type | Purpose |
|------|------|---------|
| `nix/bazel-repo-cache.nix` | Function | `fetchurl` → linkFarm repo cache |
| `nix/gen-bazel-deps.py` | Script | Lockfile parser → bazel-deps.nix |
| `nix/bazel-deps.nix` | Generated | Archive list (254 entries) |
| `nix/nixify-rules.nix` | Config | Extensible fixup pipeline rules |
| `nix/redpanda.nix` | Derivation | Uses linkFarm + nixify pipeline |

## Verification

1. `--repository_disable_download` proves cache completeness (fails fast if missing)
2. `nix build .#redpanda` produces working binary
3. Test binary with rpk topic produce/consume
4. Compare with dev-shell build output

## MODULE.bazel Patches (Applied by src Derivation)

The Nix build patches MODULE.bazel to work in the sandbox:

1. **`go_sdk.host()`** replaces `go_sdk.download(version = "1.25.7")` —
   `go_sdk.download()` first fetches a JSON version list from go.dev (dynamic,
   no content hash, uncacheable). `go_sdk.host()` uses Go from PATH instead.

2. **`single_version_override` for rules_cc** — Fixes `#!/usr/bin/env bash`
   shebangs to `#!/bin/sh` via `patch_cmds`. The Nix sandbox only provides
   `/bin/sh` (which is bash); `/bin/bash` and `/usr/bin/env` don't exist.
   Must handle BOTH `#!/usr/bin/env bash` and `#!/bin/bash` patterns.

3. **`single_version_override` for rules_buf** — Stubs out buf toolchain
   downloads (not needed for C++ build).

4. **`go_sdk_with_systemcrypto` removed** — FIPS variant not needed in Nix.

5. **`local_path_override` for rules_python** — Uses embedded fork.

6. **`exec_os = "linux"` for toolchains_llvm** — Skips `/etc/os-release` detection.

**IMPORTANT**: Every MODULE.bazel change requires lockfile regeneration:
```bash
# Apply all patches to MODULE.bazel locally
bazel fetch --lockfile_mode=update //src/v/redpanda:redpanda
cp MODULE.bazel.lock nix/MODULE.bazel.lock.nix
# Restore original MODULE.bazel
```

## Environment Variables for Sandbox

- `BAZEL_SH=${bash}/bin/bash` — MUST be exported as a real env var (not just
  `--repo_env`). `patch_cmds` runs during module resolution phase, which reads
  the process environment, not `--repo_env`.
- `USE_BAZEL_VERSION` — Points to Nix bazel_8 platform binary for bazelisk.
- `BAZEL_HTTP_RULES_URLS_AS_DEFAULT_CANONICAL_ID=0` — Pure content-addressing.

## Known Gap: Dev Dependency Extensions

Extensions marked `dev_dependency = True` (go_sdk, rust, crate internals) are
NOT stored in `MODULE.bazel.lock`. This means `gen-bazel-deps.py` cannot capture
their archives from the lockfile. Current status:

- **Go SDK**: Solved — `go_sdk.host()` avoids all downloads
- **Rust toolchain**: TODO — archives from `static.rust-lang.org` not in cache
- **Rust internal crates**: TODO — `tinyjson`, `semver`, etc. from `static.crates.io`
- **cargo-bazel binary**: TODO — from GitHub releases, needed by crate_universe
- **Python pip packages**: TODO — from `pypi.org`, needed by rules_python pip ext

These ~500 archives need to be added to `bazel-deps.nix` via:
(a) Expanding `gen-bazel-deps.py` to extract from Bazel's repo cache, or
(b) Manual export + `nix-prefetch-url`

## Advantages Over Previous FOD Approach

1. **Incremental caching** — per-archive, not all-or-nothing
2. **No FOD hash management** — no `lib.fakeHash` → build → update cycle
3. **Deterministic** — content-addressed, reproducible, auditable
4. **Solves `/bin/bash`** — nixify pipeline handles shebangs post-extraction
5. **Generic** — same pattern works for any Bazel project in Nix
6. **Provably complete** — `--repository_disable_download` fails fast
