# Bazel Cache Leak Into Nix Sandbox: Analysis

## Summary

We implemented `extra-sandbox-paths` to bind-mount a persistent Bazel cache
(`/var/cache/bazel-nix/`) into the Nix sandbox, with `--output_base` forcing
Bazel to use it. The goal: avoid recompiling ~7,600 actions from scratch when
only the Nix derivation hash changes (e.g., touching `nix/entropy`).

**Result**: Partial success. The action cache works (64% hit rate), but
compilation actions mostly re-execute despite apparently identical inputs.

| Metric | Cold Build | Warm Build |
|--------|-----------|------------|
| Wall time | 36m 04s | 31m 46s |
| Build phase | 34m 46s | 31m 36s |
| Fetch phase | 26s | 7s |
| Total actions | 7,662 | 7,697 |
| Local (compile/link) | 3,103 | 2,709 |
| Internal (fetch/extract) | 4,559 | 61 |
| Action cache hits | 0 | 4,927 |
| Critical path | 464s | 450s |

**Savings**: ~4 minutes (11%). Internal/fetch actions are heavily cached (98.7%),
but compilation actions are barely cached (12.7%).

## What Works

### Repo extraction is cached

The persistent `output_base/external/` directory preserves extracted external
repos across builds. On the warm build, the fetch phase took 7s (vs 26s cold)
because Bazel found already-extracted repos.

### Nixify patches are preserved

On the cold build, the nixify patcher modified:
- 35 ELF binaries (cmake, ninja, Rust toolchain) — patchelf interpreter/rpath
- Many shebangs across rules_rust, rules_foreign_cc, rules_python, etc.

On the warm build, the patcher found:
- **0 ELF binaries** needed patching (all already had `/nix/store` interpreters)
- Only `rules_python+` shebangs needed re-patching (Bazel re-extracted this one repo)

This confirms the persistent cache preserves the patched externals correctly.

### Build outputs persist

The `bazel-out/` directory (3.4 GB) persists in the output_base, containing
compiled `.o` files, linked binaries, etc. from the previous build.

### Workspace status is deterministic

Nix sets `BUILD_TIMESTAMP` to a fixed epoch (315532800 = Jan 1, 1980).
`BUILD_HOST` is `localhost`, `BUILD_USER` is `nixbld`. The `volatile-status.txt`
and `stable-status.txt` are identical between builds — no timestamp-based
invalidation.

## The Mystery: Why Do 2,709 Compilation Actions Re-Execute?

External dependencies like `absl`, `upb`, `lz4` were recompiled on the warm
build — not just Redpanda source files. These deps absolutely did not change
between builds.

### What's identical between builds

| Component | Same? | Evidence |
|-----------|-------|----------|
| Source tree content (except entropy) | Yes | Same git content, same patches |
| External repos (headers, etc.) | Yes | Nixify patcher found nothing to patch |
| Compiler (clang) | Yes | Same nixpkgs → same store path |
| Build flags (.bazelrc.nix) | Yes | All Nix store paths unchanged |
| Workspace path | Yes | Always `/build/redpanda-src-patched` |
| Status files | Yes | Fixed timestamp, deterministic host/user |
| output_base path | Yes | `/var/cache/bazel-nix/output_base` |

### What's different between builds

| Component | Different? | Details |
|-----------|------------|---------|
| `nix/entropy` file | Yes | Intentionally changed to invalidate Nix |
| `$HOME` | Yes | `$(mktemp -d)` creates new tmpdir each build |
| Source file inodes/mtimes | Yes | Fresh tmpfs copy of source tree |
| Execroot symlinks | Recreated | Same targets, but new symlinks |

### Hypothesis 1: `nix/entropy` cascading through Bazel (Unlikely)

`nix/entropy` is not referenced by any BUILD file. There is no BUILD file in
`nix/`. The `nix/` directory is not in `.bazelignore`, but Bazel only processes
directories with BUILD files. External deps (absl, etc.) definitely don't depend
on `nix/entropy`.

**Verdict**: Not the cause. External deps would not be affected.

### Hypothesis 2: File stat changes cause digest cache misses (Possible)

Each Nix build creates a fresh tmpfs at `/build/`. All source files get new
inodes and mtimes. Bazel maintains a file digest cache mapping
`(path, inode, mtime, size) → content_digest`. When stats change, Bazel must
recompute content digests.

However, recomputed digests should be identical (same file content), so action
cache keys should still match. This adds overhead (re-hashing ~5,000 source
files) but should not cause action cache misses.

**Verdict**: Explains slowdown from re-hashing but NOT why actions re-execute.

### Hypothesis 3: Bazel's action cache is not fully content-addressable for local execution (Most Likely)

Bazel's local action cache in `output_base/action_cache/` may behave
differently than a remote cache or `--disk_cache`. Specifically:

1. **The local action cache may include the execution root's file system state
   (inodes, timestamps) in its validity checks**, not just content digests.
   When the workspace is on a fresh tmpfs, ALL source file stats differ, causing
   Bazel to consider the cached action entries "stale" even though content
   is identical.

2. **Server restart clears in-memory state**. Between builds, `bazelisk shutdown`
   stops the Bazel server. On restart, Bazel loads the on-disk action cache but
   may need to re-validate entries against the current filesystem state. If
   validation uses stat-based checks (fast path), it would find mismatches on
   the fresh tmpfs.

3. **Skyframe invalidation**: Bazel's internal dependency graph (Skyframe) is
   rebuilt on server restart. During rebuild, Bazel may conservatively invalidate
   actions whose input directories have changed inodes, even if file content is
   the same. This would explain why external deps (with preserved stats in the
   persistent output_base) show SOME cache hits, while source files (on fresh
   tmpfs) cause misses that cascade.

This hypothesis explains the observed pattern:
- **4,927 cache hits**: Mostly internal/fetch actions and some compilation actions
  whose inputs are entirely in the persistent output_base (external deps)
- **2,709 cache misses**: Compilation actions that depend on source files (fresh
  tmpfs) or that transitively depend on actions with invalidated inputs

**Verdict**: Most likely explanation. The action cache is partially working but
filesystem stat changes on the workspace tmpfs cause cascading invalidation
through Bazel's dependency graph.

### Hypothesis 4: `$HOME` variation leaking into action environment (Possible)

`$HOME` is set to `$(mktemp -d)` — different each build. While `$HOME` is not
in our `--action_env` flags, some Bazel action types (genrule, shell rules) may
inherit `$HOME` from the process environment with `--spawn_strategy=local`. If
genrule actions produce different outputs (due to different `$HOME`), downstream
compilation actions depending on those outputs would also be invalidated.

**Verdict**: Could contribute. Worth testing with `export HOME=/tmp/bazel-home`
(fixed path).

### Hypothesis 5: Bazel re-extracts repos, invalidating the action graph (Partially Confirmed)

The warm build log shows Bazel re-extracted `rules_python+` during the fetch
phase (its shebangs needed re-patching). When Bazel re-extracts a repo, it
creates fresh files with new timestamps. This could invalidate any action that
depends on files from that repo.

However, most repos were NOT re-extracted (the nixify patcher found no ELFs or
other shebangs to fix). So this only explains a small subset of the 2,709
re-executed actions.

**Verdict**: Partial contributor, not the main cause.

## Experiment 2: `--disk_cache` + `--execution_log_json_file` + stable `$HOME`

### Changes Made (2026-03-18)

Added to `nix/redpanda.nix`:
1. **`--disk_cache=${bazelCacheDir}/disk_cache`** — content-addressable cache
   using REv2 protocol (keyed by action digest, no filesystem metadata in keys)
2. **`--execution_log_json_file`** — captures full action details (command args,
   env vars, input digests) for both builds, with rotation
3. **Stable `$HOME=/tmp/bazel-home`** — eliminates `mktemp -d` non-determinism
4. **Execution log rotation** — renames previous log before each build for diff

### Results

| Metric | Cold Build | Warm Build |
|--------|-----------|------------|
| Wall time | 38m 13s | 33m 50s |
| Build phase | 35m 08s | 33m 40s |
| Total actions | 7,662 | 7,662 |
| Local (compile/link) | 3,103 | **2,709** |
| Internal | 4,559 | 60 |
| Action cache hits | 0 | **4,928** |
| Critical path | 497s | 457s |

**Verdict**: No improvement. Same 2,709 actions re-execute. The disk cache
did not help — it uses the same action digests as the internal action cache,
so if inputs hash differently, both caches miss.

### Root Cause Found: `NIX_CFLAGS_COMPILE` contains `-frandom-seed=<hash>`

The execution log reveals the definitive root cause:

```
# Cold build:
NIX_CFLAGS_COMPILE=" -frandom-seed=zk1pd4i5bm ..."

# Warm build:
NIX_CFLAGS_COMPILE=" -frandom-seed=9jpnvas53r ..."
```

The `-frandom-seed` value is a **10-character prefix of the Nix output path
hash**. Nix's stdenv injects this into `NIX_CFLAGS_COMPILE` automatically to
make builds reproducible. But when we change `nix/entropy`, the derivation
hash changes, which changes the output path, which changes the random seed.

Since `NIX_CFLAGS_COMPILE` is passed to Bazel via `--action_env`, it becomes
part of **every C/C++ compilation action's cache key**. A different
`-frandom-seed` means a different action key → cache miss for ALL 2,709
compilation actions. This defeats both the action cache AND the disk cache.

### Why the Other 4,928 Actions Still Cache

The cached actions are "internal" Bazel operations (archive extraction,
file copying, tree creation) that don't use `NIX_CFLAGS_COMPILE`. Their
cache keys are unaffected by the changing env var.

### Fix Options

#### Option A: Strip `-frandom-seed` from `NIX_CFLAGS_COMPILE` (Recommended)

Override the env var before Bazel runs to remove the problematic flag:

```bash
export NIX_CFLAGS_COMPILE="$(echo "$NIX_CFLAGS_COMPILE" | sed 's/-frandom-seed=[^ ]*//')"
```

This is safe because Bazel's own `-frandom-seed` (set to the output .o path)
is passed separately in `commandArgs`, providing the same determinism benefit.

#### Option B: Don't pass `NIX_CFLAGS_COMPILE` via `--action_env`

Remove `--action_env=NIX_CFLAGS_COMPILE` from `bazelrcNix`. The env var would
still be in the process environment but wouldn't be part of the action cache key.

Risk: this might break compilation if Bazel's cc rules depend on inheriting
`NIX_CFLAGS_COMPILE` to find Nix include paths. The `-isystem` entries in
`NIX_CFLAGS_COMPILE` are critical for finding Nix-provided headers.

#### Option C: Set a fixed `-frandom-seed` in `.bazelrc.nix`

Add `build --copt=-frandom-seed=redpanda-nix` to override the Nix-injected one
with a stable value.

Risk: might conflict with Bazel's own per-object `-frandom-seed`.

## Potential Improvements (from Experiment 1)

### 1. Skip nixify for already-patched externals

Add a sentinel file after patching:
```bash
if [ ! -f "${bazelCacheDir}/output_base/.nixified" ]; then
  ${patchBazelDirs}
  touch "${bazelCacheDir}/output_base/.nixified"
fi
```

This avoids modifying any file timestamps in the persistent cache.

### 2. Use nixpkgs packages instead of recompiling externals

Many of Bazel's external deps (abseil, protobuf, zlib, lz4, etc.) are available
as pre-built nixpkgs packages. Replacing Bazel-managed externals with nixpkgs
equivalents would:
- Eliminate compilation of those deps entirely (pre-built in Nix binary cache)
- Reduce the number of repos to extract and nixify
- Shrink the persistent cache size

See the follow-up investigation for feasibility of this approach.

## Raw Data

### Experiment 1 (baseline: output_base only)

#### Cold build
```
INFO: Elapsed time: 1732.153s, Critical Path: 464.10s
INFO: 7662 processes: 4559 internal, 3103 local.
INFO: Build completed successfully, 7662 total actions
buildPhase completed in 34 minutes 46 seconds
```

#### Warm build
```
INFO: Elapsed time: 1572.041s, Critical Path: 449.96s
INFO: 2770 processes: 4927 action cache hit, 61 internal, 2709 local.
INFO: Build completed successfully, 2770 total actions
buildPhase completed in 31 minutes 36 seconds
```

### Experiment 2 (+ disk_cache, exec log, stable $HOME)

#### Cold build
```
INFO: Elapsed time: 1678.481s, Critical Path: 496.73s
INFO: 7662 processes: 4559 internal, 3103 local.
INFO: Build completed successfully, 7662 total actions
buildPhase completed in 35 minutes 8 seconds
```

#### Warm build
```
INFO: Elapsed time: 1628.537s, Critical Path: 457.02s
INFO: 2769 processes: 4928 action cache hit, 60 internal, 2709 local.
INFO: Build completed successfully, 2769 total actions
buildPhase completed in 33 minutes 40 seconds
```

### Persistent cache size
```
/var/cache/bazel-nix/                  6.1 GB total
  output_base/external/                ~2.5 GB (extracted repos)
  output_base/execroot/_main/bazel-out/  3.4 GB (compilation outputs)
  output_base/action_cache/              5.2 MB (action metadata)
  disk_cache/                           (new, content-addressable)
```
