# Design: Nix-Managed Bazel Repository Cache

## Context

Building Redpanda via `nix build` requires running Bazel inside Nix's sandbox, where
there is no network access. Currently a Fixed-Output Derivation (FOD) runs `bazel fetch`
with network access to download ~470 archives, then a multi-pass patchelf loop fixes
ELF binaries. This approach is fragile: the FOD hash is all-or-nothing (any MODULE.bazel
change invalidates everything), and scripts with `#!/bin/bash` shebangs (like rules_cc's
`generate_system_module_map.sh`) can't be fixed because Bazel re-extracts from cache.

The new approach pre-populates Bazel's repository cache using individual Nix `fetchurl`
derivations, giving us per-archive caching, deterministic downloads, and the ability to
apply patches via Bazel's native `single_version_override` mechanism.

## How Bazel's Repository Cache Works

(Source: `~/Downloads/bazel/src/main/java/.../repository/cache/DownloadCache.java`)

```
<repo-cache>/content_addressable/sha256/<64-hex-chars>/file
```

- Lookup is by **content hash only** - Bazel computes sha256 of the desired file
  and checks `content_addressable/sha256/<hex>/file`
- **Canonical ID markers** (`id-<hash>` files) add an extra check, but can be
  disabled with `--repo_env=BAZEL_HTTP_RULES_URLS_AS_DEFAULT_CANONICAL_ID=0`
  (used by Bazel's own bootstrap: `scripts/bootstrap/bootstrap.sh`)
- Bazel's own `distdir.bzl` uses this exact pattern to create offline bootstrap
  tarballs - downloading each archive and placing it at
  `content_addressable/sha256/<sha256>/file`

Download priority in `DownloadManager.downloadInExecutor()`:
1. File already at destination with correct hash
2. Repository cache (`--repository_cache`)
3. Distdir (`--distdir`)
4. Network download
5. Store result in repository cache

## Architecture

```
                     ┌─────────────────────────────────┐
                     │   MODULE.bazel.lock (JSON)       │
                     │   MODULE.bazel (archive_override) │
                     │   BCR source.json files           │
                     └──────────┬──────────────────────┘
                                │
                     ┌──────────▼──────────────────────┐
                     │  nix/gen-bazel-deps.py           │
                     │  Parses lockfile + BCR + MODULE  │
                     │  Outputs nix/bazel-deps.nix      │
                     └──────────┬──────────────────────┘
                                │  (run manually when deps change)
                     ┌──────────▼──────────────────────┐
                     │  nix/bazel-deps.nix              │
                     │  [ { url, sha256, name } ... ]   │
                     │  ~240 archives                   │
                     └──────────┬──────────────────────┘
                                │
                     ┌──────────▼──────────────────────┐
                     │  nix/bazel-repo-cache.nix        │
                     │  mkBazelRepoCache function       │
                     │                                  │
                     │  For each archive:               │
                     │    fetchurl { url; sha256; }     │
                     │  Assemble via linkFarm:           │
                     │    content_addressable/           │
                     │      sha256/<hex>/file → /nix/.. │
                     └──────────┬──────────────────────┘
                                │
                     ┌──────────▼──────────────────────┐
                     │  nix/redpanda.nix                │
                     │  bazel build                     │
                     │    --repository_cache=<cache>    │
                     │    --repo_env=BAZEL_HTTP_RULES.. │
                     │    --repository_disable_download │
                     │    --registry=file://<bcr>       │
                     └─────────────────────────────────┘
```

## What Needs Caching

From analyzing MODULE.bazel.lock:

| Category | Count | Source of URL+hash |
|----------|-------|--------------------|
| BCR registry files (MODULE.bazel, source.json) | ~280 | `registryFileHashes` in lockfile |
| BCR module archives (tarballs) | ~51 | `source.json` in local BCR snapshot |
| Extension-generated downloads | ~189 | `moduleExtensions.*.generatedRepoSpecs` |
| archive_override modules | ~2 | `MODULE.bazel` directly |
| **Total unique sha256** | **~468** | |

**Note:** BCR registry files (~280) may not need caching when using
`--registry=file://<local-bcr>` since Bazel reads them directly from the filesystem.
Testing will confirm whether the ~51 module archives + ~189 extension downloads are
sufficient, or if registry files also need cache entries.

## Key Design Decisions

### 1. Use `--repository_cache` (not `--distdir`)

- `--distdir` matches by **filename** then verifies hash - fragile (many files named `v1.2.3.tar.gz`)
- `--repository_cache` is pure **content-addressable** lookup by hash - exact, no ambiguity
- This is what Bazel's own bootstrap uses (`distdir.bzl` → `content_addressable/sha256/<hash>/file`)

### 2. Disable canonical IDs

Set `--repo_env=BAZEL_HTTP_RULES_URLS_AS_DEFAULT_CANONICAL_ID=0`.

Without this, Bazel requires `id-<hash_of_urls>` marker files alongside each `file` entry.
Creating these is possible but adds complexity. Disabling it makes the cache purely
content-addressed. Bazel's own bootstrap does exactly this.

### 3. Use `linkFarm` (not a single derivation)

Each archive is an independent `fetchurl` derivation. Adding/removing one module doesn't
invalidate any others. The `linkFarm` just creates a directory of symlinks to Nix store
paths - trivial to rebuild. Bazel reads (copies) from the cache, so symlinks work fine.

### 4. Patch via Bazel's native mechanisms (not in the cache)

Patching an archive changes its hash, breaking content-addressing. Instead:
- Store **original** archives in the cache (correct hashes, Bazel finds them)
- Apply patches **after extraction** using `single_version_override(patches=[...])` in MODULE.bazel
- This is how Bazel is designed to work - patches are a native concept

### 5. Hash format: always hex sha256

- Lockfile `registryFileHashes` uses hex sha256 directly
- Extension repos use hex sha256 in `attributes.sha256`
- SRI integrity (`sha256-<base64>`) from BCR `source.json` needs conversion to hex
- The generator script normalizes everything to hex for both the cache path and `fetchurl`

## Implementation Plan

### Step 1: Create `nix/bazel-repo-cache.nix`

Generic function that takes a list of `{ url, sha256, name }` and produces
a repository cache directory:

```nix
{ lib, fetchurl, linkFarm }:

archives:

let
  entries = map (a: {
    name = "content_addressable/sha256/${a.sha256}/file";
    path = fetchurl {
      url = a.url;
      sha256 = a.sha256;
      name = a.name or "source";
    };
  }) archives;
in linkFarm "bazel-repo-cache" entries
```

### Step 2: Create `nix/gen-bazel-deps.py`

Python script that generates `nix/bazel-deps.nix` by parsing:

1. **`MODULE.bazel.lock`** → `registryFileHashes` (url → sha256 pairs for registry files)
2. **Local BCR `source.json` files** → URL + integrity (SRI) for module archives
   - Convert SRI `sha256-<base64>` → hex via `base64.b64decode` + `.hex()`
   - Also collect patch/overlay URLs from source.json
3. **`MODULE.bazel.lock`** → `moduleExtensions.*.generatedRepoSpecs.*.attributes`
   - Extract `sha256` (hex) and `url`/`urls[0]`
   - Only for rules with `ruleClassName` ending in `http_archive`, `http_file`, `http_jar`
4. **`MODULE.bazel`** → `archive_override` entries (URL + integrity)

Output format:
```nix
# Auto-generated by nix/gen-bazel-deps.py — do not edit manually
# Run: python3 nix/gen-bazel-deps.py > nix/bazel-deps.nix
[
  { url = "https://github.com/abseil/...tar.gz"; sha256 = "abc123..."; name = "abseil-cpp"; }
  { url = "https://..."; sha256 = "def456..."; name = "rules_cc"; }
  # ...
]
```

### Step 3: Create shebang patch for rules_cc

Create `bazel/thirdparty/rules_cc-nix-shebang.patch`:
```diff
--- a/cc/private/toolchain/generate_system_module_map.sh
+++ b/cc/private/toolchain/generate_system_module_map.sh
@@ -1,4 +1,4 @@
-#!/bin/bash
+#!/usr/bin/env bash
```

Add to MODULE.bazel (via the source-patching step in `redpanda.nix`):
```starlark
single_version_override(
    module_name = "rules_cc",
    patches = ["//bazel/thirdparty:rules_cc-nix-shebang.patch"],
)
```

### Step 4: Modify `nix/redpanda.nix`

Replace the current FOD-based approach:

**Before:** Single FOD runs `bazel fetch` with network → patchelf loop → copies repo_cache
**After:**

```
bazelRepoCache = import ./bazel-repo-cache.nix { inherit lib fetchurl linkFarm; }
                   (import ./bazel-deps.nix);
```

Add to `commonArgs`:
```nix
"--repository_cache=${bazelRepoCache}"
"--repo_env=BAZEL_HTTP_RULES_URLS_AS_DEFAULT_CANONICAL_ID=0"
"--repository_disable_download"
```

**For ELF binary patching (Go SDK, Rust toolchain):**
Keep a slim FOD that:
- Uses `--repository_cache=${bazelRepoCache}` (no downloads needed!)
- Runs `bazel fetch` (extraction + repo rule execution only)
- Applies patchelf to extracted ELF binaries
- Outputs the patched external repos

OR: Apply patchelf inline in the build phase (between fetch and build),
avoiding the FOD entirely. The `--repository_disable_download` flag proves
completeness (build fails immediately if any archive is missing from cache).

### Step 5: Generate initial `bazel-deps.nix`

```bash
python3 nix/gen-bazel-deps.py \
  --lockfile MODULE.bazel.lock \
  --bcr /nix/store/...-bazel-central-registry \
  --module-bazel MODULE.bazel \
  > nix/bazel-deps.nix
```

### Step 6: Test and iterate

1. `nix build .#redpanda` — should fail with `--repository_disable_download`
   if any archive is missing from the cache
2. Add missing archives to `bazel-deps.nix` (or fix the generator)
3. Verify the `rules_cc` shebang patch resolves the `/bin/bash` blocker
4. Verify ELF patching still works for Go/Rust toolchain binaries

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `nix/bazel-repo-cache.nix` | **Create** | Generic `mkBazelRepoCache` function |
| `nix/gen-bazel-deps.py` | **Create** | Script to generate deps list from lockfile |
| `nix/bazel-deps.nix` | **Create** (generated) | List of `{ url, sha256, name }` records |
| `nix/redpanda.nix` | **Modify** | Use linkFarm cache instead of FOD download |
| `bazel/thirdparty/rules_cc-nix-shebang.patch` | **Create** | Fix `#!/bin/bash` in rules_cc |

## Advantages Over Current Approach

1. **Incremental caching**: Each archive is a separate Nix `fetchurl` — adding/removing
   one doesn't invalidate ~470 others
2. **No FOD hash management**: No more `lib.fakeHash` → build → get hash → update cycle
   for the download phase
3. **Deterministic**: Content-addressable, reproducible, auditable
4. **Solves the `/bin/bash` problem**: `single_version_override` patches are applied
   after extraction, so the cache stores the original (correct-hash) archive
5. **Generic**: The same `mkBazelRepoCache` pattern works for any Bazel project in Nix
6. **Provably complete**: `--repository_disable_download` fails fast if any dep is missing

## Resolved Decisions

- **ELF patching**: Inline in the build phase. No FOD at all for downloading.
  The main derivation runs `bazel fetch` (from cache, no network), then patchelf,
  then `bazel build`. `--repository_disable_download` proves cache completeness.

- **Integrity vs sha256**: `fetchurl` supports `hash = "sha256-<base64>"` natively.
  The generator script will normalize to hex for cache paths but can use SRI for fetchurl.

## Open Questions

1. **Registry files**: Do we need to cache the ~280 BCR registry files when using
   `--registry=file://<local-bcr>`? Or does the local registry bypass the cache entirely?
   → Test empirically with `--repository_disable_download`

## Verification

1. Build with `--repository_disable_download` — proves cache completeness
2. `nix build .#redpanda` produces a working binary
3. Test binary with `rpk topic produce`/`consume` (existing test from bench-log.md)
4. Compare build output with dev-shell Bazel build to verify identical binary
