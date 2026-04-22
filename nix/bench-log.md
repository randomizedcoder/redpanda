# Nix Build Benchmark: Progress Log

## Step 1: Rewrite nix/redpanda.nix

- Rewrote from 435 lines (bwrap + FHS namespace) to ~230 lines (system-clang + patchelf)
- Removed: bubblewrap, fhsLibs, fhsBin, fhsEtc, fetchFromGitHub for source
- Added: local source with `lib.cleanSourceWith` filter, `.bazelrc.nix` generation inside derivation
- Added: `--config=system-clang` (uses Nix-provided clang, no LLVM download)
- Added: rules_python embedded in source tree via `builtins.path` + `sed` rewrite of `local_path_override`
- Kept: `patch_one_elf` / `patch_elfs` helpers (proven), multi-pass fetch-patch loop, BCR registry, `--spawn_strategy=local`

## Step 2: Update flake.nix

- Removed `nixpkgsSrc` arg (no longer needed — source is local)
- Added `apps` output from `nix/bench.nix`
- Added `flake-utils` passthrough to bench.nix for `mkApp`

## Step 3: Create nix/bench.nix

- Created `mkBench` and `mkClearOnly` helper functions
- 11 targets: clear-nix, clear-bazel, clear-all, bench-no-nix, bench-no-bazel, bench-no-cache, bench-cached, bench-3x-cached, bench-3x-nix-only, bench-3x-bazel-only, bench-matrix
- FOD store path exposed via `passthru.bazelRepoCachePath`

## Step 4: Create nix/entropy + .gitignore

- Created initial `nix/entropy` timestamp file
- Initially added `nix/entropy` to `.gitignore` — later removed (see Step 7 Issue B)

## Step 5: Fix rules_python source fetching

- `builtins.path` with absolute path `/home/das/Downloads/rules_python` fails in pure evaluation mode
- Error: "access to absolute path '/home' is forbidden in pure evaluation mode"
- Fix: switched to `builtins.fetchGit` with local URL, ref, and rev — works in pure flake evaluation

## Step 6: Verification of infrastructure

- `nix flake show` — all 11 apps, packages, devShells, checks evaluate cleanly
- `nix develop --command clang --version` — shell works, clang 20.1.8
- `nix run .#clear-nix` — writes entropy file
- `nix run .#clear-bazel` — deletes FOD store path (reports "1 store paths deleted")
- `nix run .#clear-all` — both operations work

## Step 7: First `nix build .#redpanda` attempt

- FOD hash `lib.fakeHash` → got `sha256-t3fnu0sXp4fvq0XWy736+i2Xa8hTTpVGMDJZfaAnqho=`
- **Issue A: rules_python `local_toolchain` tag class not found**
  - Error: `The module extension ... does not have a tag class named local_toolchain`
  - `builtins.fetchGit` rev `18d0d297` was from `main`, not the patched branch
  - The patch was uncommitted working tree changes on `nix-local-toolchain` branch
  - Fix: committed the patch in rules_python repo → new rev `b65ba9d6`
  - Updated `redpanda.nix` to use the new rev
- **Issue B: entropy file must NOT be in .gitignore**
  - The whole point is that changing entropy changes the source hash → invalidates Nix cache
  - If gitignored, Nix's flake source filter excludes it → it has no effect
  - Fix: removed `nix/entropy` from `.gitignore`, staged the file with `git add`

## Step 8: Second `nix build .#redpanda` attempt

- FOD hash changed to `sha256-JYCsLqEo4KuVJiXFCAqBOMqNyVF2Y+OztPHex/KUJC0=` (different source)
- rules_python `local_toolchain` error RESOLVED — `local_path_override` correctly points at `third_party/rules_python` which now contains the committed patch

### Issue C: `generate_system_module_map.sh` — the `/bin/bash` problem

**Error:** `execvp(.../generate_system_module_map.sh, ...): No such file or directory`

This is the current blocking issue. It's a deeper instance of the same class
of problem described in `nix-build-journey.md` Section 5 (the sandbox
composition problem), but for shell scripts rather than ELF binaries.

**Root cause chain:**

1. `rules_cc`'s `cc_configure_extension` creates the `local_config_cc` repo
2. That repo rule calls `repository_ctx.execute()` on `generate_system_module_map.sh`
3. The script has `#!/bin/bash` as its shebang
4. The Nix sandbox provides `/bin/sh` but NOT `/bin/bash`
5. The kernel follows the shebang, can't find `/bin/bash`, returns `ENOENT`
6. Bazel's `process-wrapper-legacy` reports "No such file or directory"

**Why this is harder than the ELF problem:**

The ELF problem (Python, Rust, Go binaries having `/lib64/ld-linux-x86-64.so.2`
interpreter) is solvable with the multi-pass fetch-patch loop because those
binaries are downloaded as archives, extracted, and *then* executed. There's a
window between extraction and execution where we can patch.

The `generate_system_module_map.sh` script is different: it's part of `rules_cc`
itself (not a downloaded toolchain binary). It's extracted from the BCR archive
and executed in the same `repository_ctx.execute()` call within the repo rule.
The script exists in `external/rules_cc+/cc/private/toolchain/` — we can patch
it after fetch attempt 1 fails, but the `cc_configure_extension` repo rule
re-evaluates on fetch attempt 2 and Bazel may re-extract the module from cache,
restoring the original unpatched shebang.

**Why existing Bazel flags don't help:**

| Flag | What it does | Why it doesn't help |
|------|-------------|-------------------|
| `--shell_executable` | Sets shell for `ctx.actions.run_shell()` | Only affects build actions, not repo rules |
| `--spawn_strategy=local` | Disables Bazel's sandbox for actions | Only affects build actions, not `repository_ctx.execute()` |
| `--action_env=PATH` | Sets PATH for actions | Not used by repo rule script execution |
| `--repo_env=PATH` | Sets PATH for repo rules | Doesn't affect shebang resolution (that's kernel-level) |

**What we tried:**

1. **Custom `patch_shebangs` function** — rewrites `#!/bin/bash` to `#!${bash}/bin/bash`
   in shell scripts found under the external/ directory. Applied between fetch
   attempts just like `patch_elfs`. Problem: the `cc_configure_extension` repo
   rule may re-extract `rules_cc` from cache on retry, losing the patch.

2. **Nix's built-in `patchShebangs`** — the stdenv function that rewrites all
   shebangs to Nix store paths. Problem: it aggressively patches everything
   (hundreds of Python .py files in the downloaded CPython toolchain) and fails
   with a `chmod` error on `idle3.12` (`new permissions are r-xrwxr-x, not
   r-xr-xr-x`). This aborts the entire build before we get to fetch attempt 2.

3. **`__noChroot = true`** on the FOD — would disable the Nix sandbox entirely,
   providing `/bin/bash` from the host. Problem: Nix refuses when
   `sandbox = true` in nix.conf (`has '__noChroot' set, but that's not allowed
   when 'sandbox' is 'true'`). Would require `sandbox = relaxed` in nix.conf.

4. **`--option extra-sandbox-paths`** — pass `/bin/bash=.../bash` on the
   command line. Problem: this is a Nix daemon config option, not a derivation
   attribute — it doesn't change the derivation hash, so the cached failure
   replays. The cached FOD output needs to be deleted first. Also requires
   `trusted-users` in nix.conf for the option to take effect.

5. **`writeShellApplication` for patcher** — refactored the inline bash
   helpers into a proper shellcheck-validated script (`bazel-sandbox-patcher`).
   Cleaner code, but doesn't solve the fundamental `/bin/bash` problem.

**Key insight from the dev shell comparison:**

The dev shell (`nix develop`) works because it runs *outside* the Nix sandbox.
The host system provides `/bin/bash`, `/lib64/ld-linux-x86-64.so.2`, and all
other FHS paths. Inside `nix build`, the Nix sandbox creates a minimal
filesystem with only `/bin/sh`, `/nix/store`, and explicitly allowed paths.

The system already has `extra-sandbox-paths = ... /lib64` in `/etc/nix/nix.conf`
(for binfmt/qemu), which is why ELF binaries with `/lib64/ld-linux-x86-64.so.2`
interpreter can run. We just need the same treatment for `/bin/bash`.

## Next Steps

### Option A: Add `/bin/bash` to nix.conf (simplest, recommended)

Add to `/etc/nix/nix.conf` (NixOS: `nix.settings.extra-sandbox-paths`):

```
extra-sandbox-paths = /bin/bash=${bash-path}/bin/bash
```

This is the same mechanism already used for `/lib64`. It provides `/bin/bash`
inside every Nix sandbox build. After this:

1. Delete the cached failed FOD: `nix store delete /nix/store/...-redpanda-bazel-repo-cache`
2. Rebuild: `nix build .#redpanda`
3. The `generate_system_module_map.sh` shebang will resolve, `cc_configure` will work
4. The multi-pass fetch-patch loop handles the remaining ELF binary issues
5. Get the correct FOD hash from the hash mismatch error, update `redpanda.nix`
6. Rebuild again — FOD is cached, main derivation builds

**Pros:** zero code changes, matches existing `/lib64` pattern, works for all
builds that need `/bin/bash` (not just redpanda).

**Cons:** requires system-level config change.

### Option B: Targeted patching of rules_cc scripts

Fork/patch `rules_cc` (like we did with `rules_python`) to change
`generate_system_module_map.sh` shebang from `#!/bin/bash` to
`#!/usr/bin/env bash`. Use `archive_override` or `local_path_override` in
MODULE.bazel to point at the patched version.

**Pros:** no system config needed, self-contained in the repo.

**Cons:** adds another fork to maintain, and other Bazel rules may have the
same `#!/bin/bash` problem — whack-a-mole.

### Option C: Source-level sed of rules_cc in the patched source

In the `runCommand "redpanda-src-patched"` step, also patch the BCR registry
copy of `rules_cc` to fix the shebang. This doesn't work directly because
`rules_cc` comes from BCR at fetch time, not from the source tree. But we could
potentially patch it in the repo cache post-fetch.

### Option D: Investigate if repo rules honor `--shell_executable`

It's possible that newer Bazel versions (8.x) may have added support for
`--shell_executable` in repository rules. Worth checking the Bazel source
for `ShellUtils` or `BashCommandConstructor` in the repo rule execution path.

### Recommended path

**Option A** is the right answer. The system already has `/lib64` in
`extra-sandbox-paths` for the same class of reason (FHS binaries needing host
paths). Adding `/bin/bash` is the same pattern and fixes the problem for all
Bazel builds, not just Redpanda.

After that works, the remaining work is:
1. Iterate on FOD hash (update after first successful fetch)
2. Debug any remaining build-phase errors
3. Test benchmark targets with actual timings
4. Document the `extra-sandbox-paths` requirement
