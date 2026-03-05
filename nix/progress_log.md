# Nix Flake Progress Log

Working log of discoveries, fixes, and progress while building Redpanda with Nix.

---

## Session 1 (prior sessions)

### rpk (Go CLI) - DONE
- `buildGoModule` works cleanly for `src/go/rpk/`
- Same pattern as nixpkgs' existing `redpanda-client` package
- `nix build .#rpk` succeeds, binary runs

### devShell - DONE
- `nix develop` provides bazel, python, jdk, etc.

### redpanda (C++ server) - IN PROGRESS

**Approach**: Two-phase FOD build
1. FOD phase: `bazel fetch` with network, output hash locks deps
2. Build phase: `bazel build` offline with cached repo

**Key design**: Wrap bazel with `bubblewrap` to provide `/lib64` overlay for
pre-built ELF binaries that Bazel downloads (Python, Rust, Go, LLVM toolchains).
These have `/lib64/ld-linux-x86-64.so.2` hardcoded.

**Source patches applied**:
- Remove `tools/bazel` (Bazelisk wrapper with `/usr/bin/env` shebang)
- Remove `.bazelversion` (nixpkgs bazel_8 may differ from pinned 8.4.1)
- Add `exec_os = "linux"` to `llvm.toolchain()` to skip `/etc/os-release`

---

## Session 2 (current - 2026-03-03)

### Build attempt: two blocking errors found

**Error 1: `execvp(bash, ...): No such file or directory`**

Boost's repository rule runs a patch command `rm -f doc/pdf/BUILD` via Bazel's
process wrapper. The process wrapper does `execvp("bash", ...)` which fails
because `bash` is not on PATH inside the bwrap namespace. Bazel's sandbox
expects to find `bash` at a known location.

This affects `rules_boost++non_module_dependencies+boost` - every boost library
fails to fetch because the patch step can't run.

Root cause: Bazel's process-wrapper-legacy uses `bash` to run patch commands,
and we're not providing `bash` in the bwrap PATH or at `/bin/bash`.

Fix needed: Add `--ro-bind /bin/bash` or ensure `bash` is on PATH inside bwrap.
Since we're in a Nix sandbox, `/bin/sh` may exist but `/bin/bash` does not.
Need to bind-mount bash from the Nix store.

**Error 2: `cargo-bazel` binary can't execute**

```
execvp(.../modextwd/rules_rust++crate/cargo-bazel, ...): No such file or directory
```

The `cargo-bazel` binary is downloaded by `rules_rust`'s crate_universe extension.
It's a pre-built ELF that needs `/lib64/ld-linux-x86-64.so.2`. Even though we
have the bwrap `/lib64` overlay, the issue is that `cargo-bazel` is invoked
*by Bazel's process wrapper* which itself runs *inside* the bwrap namespace.
The "No such file or directory" from execvp usually means the dynamic linker
pointed to by the ELF binary doesn't exist.

Wait - the bwrap overlay should provide `/lib64/ld-linux-x86-64.so.2`. The
error message pattern (`execvp(path, ...): No such file or directory`) is the
same as the bash one, which means the binary literally doesn't exist at that path.
Need to investigate whether `cargo-bazel` was actually downloaded successfully
or if the download itself failed.

### Fix 1: bwrap can't bind-mount onto read-only Nix sandbox root

Tried `--ro-bind bash /bin/bash` with `--dev-bind / /` but bwrap can't create
mount points on the read-only sandbox root (`/bin/bash` doesn't exist, and
`/bin` is read-only so bwrap can't create the file).

Similarly, `--tmpfs /usr` fails because `/usr` doesn't exist and `/` is read-only,
so bwrap can't `mkdir /usr` for the mount point.

**Solution**: Don't use `--dev-bind / /` at all. Build a new root from scratch:
```
bwrap \
  --ro-bind /nix /nix \
  --bind /build /build \
  --bind /tmp /tmp \
  --dev /dev \
  --proc /proc \
  --ro-bind <fhsLibs>/lib /lib64 \
  --ro-bind <fhsBin>/bin /bin \
  --ro-bind <fhsBin>/usr/bin /usr/bin \
  --ro-bind <fhsEtc> /etc \
  ...
```
Without `--dev-bind`, bwrap creates a tmpfs root and can mkdir mount points freely.

**Key insight**: bwrap with `--dev-bind / /` inherits the read-only root from
the Nix sandbox. Without it, bwrap starts with a fresh tmpfs root and we bind
individual directories into it.

### Fix 2: Bazel `$USER` lookup fails

After switching to a fresh root, Bazel fails with:
```
FATAL: $USER is not set, and unable to look up name of current user
```
No `/etc/passwd` in the new root. Fixed by creating `fhsEtc` derivation with
minimal passwd/group files plus `--setenv USER nixbld`.

### Fix 3: DNS resolution fails ("Unknown host: github.com")

Bazel can download (the FOD has network access from Nix) but DNS fails because
our fresh root has no `/etc/resolv.conf`. The Nix sandbox provides this file
at build time, but our `fhsEtc` is a pre-built derivation that can't include
the runtime resolv.conf.

**Failed attempt**: `--ro-bind /etc/resolv.conf /etc/resolv.conf` after
`--ro-bind fhsEtc /etc` - fails because `/etc` is mounted read-only and
bwrap can't create the mount point file.

**Solution**: At build time (in `buildPhase`), copy `fhsEtc` contents to a
temp dir and add the sandbox's `/etc/resolv.conf`, then bind-mount that:
```bash
export BWRAP_ETC=$(mktemp -d)
cp -r ${fhsEtc}/* $BWRAP_ETC/
[ -f /etc/resolv.conf ] && cp /etc/resolv.conf $BWRAP_ETC/resolv.conf
# then bwrap uses --ro-bind $BWRAP_ETC /etc
```

### Discoveries

- **bwrap inside Nix sandbox**: The fundamental constraint is that the Nix
  sandbox root is read-only. `--dev-bind / /` preserves this, making it
  impossible to create new mount points. Building a fresh root is the way.

- **FODs have network**: Fixed-output derivations (with `outputHash`) are
  granted network access by Nix. This is key to the bazel fetch approach.

- **Bazel env requirements**: Bazel needs `$USER`, `/etc/passwd`, `bash`,
  and DNS. All must be explicitly provided in the bwrap namespace.

- **Bazel `--shell_executable`**: Tells Bazel which bash to use for genrules
  and the process wrapper. Combined with `--action_env=PATH` and
  `--repo_env=PATH`, this overrides `--incompatible_strict_action_env`.

### Fix 3 result: DNS works, massive download progress

With the resolv.conf fix, Bazel successfully:
- Downloaded boost 1.84.0 (112 MiB), openssl 3.5.5, Go toolchain
- Resolved 432 packages, configured 65k+ targets
- Downloaded Rust toolchain (cargo, rustc, clippy, rust-std, llvm-tools)
- Fetched gazelle Go dependencies, googleapis, rules_boost, etc.

Build ran for ~38 seconds before hitting two remaining blockers.

### Remaining blockers: pre-built ELF binaries can't execute

**Blocker 1: `rules_python` host Python interpreter**

```
execvp(.../rules_python++python+python_3_12_host/python, ...): No such file or directory
```

`rules_python` downloads a pre-built Python 3.12 binary for the host platform.
The `python_3_12_host` repo creates symlinks to the platform-specific downloaded
Python (e.g., `python_3_12_x86_64-unknown-linux-gnu`). The `host_toolchain`
implementation in `toolchains_repo.bzl` uses `rctx.symlink()` to link all files
from the platform-specific repo.

The downloaded Python binary is a pre-built ELF. The `execvp` ENOENT means
either the symlink is dangling (target repo not fully fetched), or the binary
exists but the kernel can't load it (wrong dynamic linker). Our `/lib64` mount
should handle the linker, so likely the symlink target doesn't exist yet when
it's first accessed (race between repo rules).

This blocks all pip dependencies: `python_deps_312_jinja2`, `python_deps_312_jsonschema`.

**Blocker 2: `cargo-bazel` binary**

```
execvp(.../modextwd/rules_rust++crate/cargo-bazel, ...): No such file or directory
```

`rules_rust`'s `crate_universe` extension downloads a pre-built `cargo-bazel`
binary from GitHub releases. Same failure pattern. The binary is needed for
`crate.from_cargo()` splice operation which resolves Cargo.toml/Cargo.lock into
Bazel build rules.

### Analysis: root cause of ELF execution failures

Both failures share the same pattern: Bazel downloads a pre-built ELF binary
and immediately tries to `execvp()` it. The `ENOENT` (No such file or directory)
from `execvp` can mean:

1. **File literally doesn't exist** - broken symlink, failed download, or
   wrong path
2. **ELF PT_INTERP doesn't exist** - the binary requests `/lib64/ld-linux-x86-64.so.2`
   which doesn't exist (but we DO have this in our bwrap)
3. **#! interpreter doesn't exist** - not applicable for ELF binaries

Since we DO have `/lib64/ld-linux-x86-64.so.2`, it's likely case 1 for both.
For Python, the `host_toolchain` creates symlinks to a sibling repo that may
not be materialized on disk yet. For `cargo-bazel`, the download may have
stored the file at a different path than expected in the `modextwd/` directory.

### Decision: use Nix-provided tools instead of downloaded binaries

Rather than debugging why the downloaded pre-built ELF binaries can't execute
(which could involve missing shared libraries, broken symlinks, download races,
or other sandbox subtleties), we can **bypass them entirely** using Nix-provided
equivalents.

**Decision**: Use Nix packages for Python and cargo-bazel instead of letting
Bazel download pre-built binaries.

**Python approach**: Configure `rules_python` to use the Nix-provided Python
interpreter instead of downloading one. Options:
- Patch `MODULE.bazel` to use a `local_runtime_repo` pointing at the Nix Python
- Set `--repo_env=RULES_PYTHON_REPO_TOOLCHAIN_VERSION_OS_ARCH` to skip download
- Use the `.bazelrc` existing `bootstrap_impl=script` setting + ensure PATH works

**cargo-bazel approach**: Set `CARGO_BAZEL_GENERATOR_URL=file:///nix/store/.../cargo-bazel`
to point at a Nix-built binary. The env var takes precedence over the download
URL in `rules_rust`'s crate_universe extension.

**Why this is better**:
- Avoids the fundamental problem of pre-built ELF binaries in the Nix sandbox
- Nix-built binaries have correct Nix store interpreter paths (no `/lib64` needed)
- More reproducible: versions are pinned by nixpkgs, not by Bazel's download
- Simpler: fewer hacks needed in the bwrap namespace

### Trial 1: CARGO_BAZEL_GENERATOR_URL with Nix cargo-bazel

Added `--repo_env=CARGO_BAZEL_GENERATOR_URL=file://${cargo-bazel}/bin/cargo-bazel`
to provide the Nix-built `cargo-bazel` (0.17.0 from nixpkgs).

**Result**: cargo-bazel itself now runs! But it fails when trying to spawn
the downloaded Rust toolchain's `cargo` binary:
```
Error: Failed to run .../rules_rust++rust_host_tools+rust_host_tools/bin/cargo
    to get its version
    No such file or directory (os error 2)
```

`cargo-bazel` is invoked with explicit `--cargo <path>` and `--rustc <path>`
flags pointing to the downloaded Rust toolchain binaries. The Nix cargo-bazel
binary works fine (has Nix glibc interpreter), but it spawns the downloaded
`cargo` which is a pre-built ELF that can't execute.

### Trial 2: CARGO/RUSTC env vars

Added `--repo_env=CARGO=${cargo}/bin/cargo` and `--repo_env=RUSTC=${rustc}/bin/rustc`.

**Result**: No change. `cargo-bazel` is passed explicit `--cargo` and `--rustc`
CLI arguments by Bazel (from the `splicing_utils.bzl` code), so the env vars
are ignored.

### Trial 3: Patch binaries between fetch runs

Strategy: run `bazel fetch` once (which fails but downloads and extracts
toolchains), then symlink Nix binaries over the downloaded ones, then re-run.

First attempt used wrong glob: `$HOME/.cache/bazel/*/external/...`.
Actual path is: `$HOME/.cache/bazel/_bazel_nixbld/<hash>/external/...`.
Fixed to `$HOME/.cache/bazel/_bazel_*/*/external/...`.

Also patching:
- `rules_rust++rust_host_tools+rust_host_tools/bin/cargo` -> Nix cargo
- `rules_rust++rust_host_tools+rust_host_tools/bin/rustc` -> Nix rustc
- `rules_python++python+python_3_12_host/python` -> Nix python3
- `modextwd/rules_rust++crate/cargo-bazel` -> Nix cargo-bazel

**Currently testing this approach...**

### Key discovery: Bazel uses `--batch` mode

With `--batch`, Bazel exits after each command. The second `bazel fetch` call
starts a fresh Bazel server, but the cache on disk persists (it's under
`$HOME/.cache/bazel/` which is outside the bwrap namespace and persists between
calls). So patching files between runs should work if the globs are correct.

### Available Nix packages being used

- `cargo-bazel` 0.17.0 (nixpkgs)
- `python313` 3.13.12 (nixpkgs)
- `rustc` + `cargo` from nixpkgs
- `bazel_8` from nixpkgs

### Result of "patch between fetch runs" approach

**Partially successful.** The symlink patching between fetch runs only found and
replaced `rust_host_tools` binaries. It did NOT find:
- `python_3_12_host` (directory didn't match the glob)
- `cargo-bazel` in modextwd (file didn't exist at expected path)

The second `bazel fetch` still failed with both blockers:
1. `python_3_12_host` - same execvp ENOENT error
2. `cargo-bazel` splice - same "Failed to run cargo to get its version"

**Root cause discovered**: Bazel **re-evaluates failed repo rules** on each
fetch. Even if we symlink Nix binaries over the downloaded ones, Bazel recreates
the `python_3_12_host` and `rust_host_tools` repos from scratch, re-running
their implementation functions (which re-create symlinks from the downloaded
platform-specific repos). Our symlinks get overwritten.

**However**, the underlying platform-specific repos (e.g.,
`python_3_12_x86_64-unknown-linux-gnu`, `rust_linux_x86_64__...__stable_tools`)
persist between fetches since they're pure downloads (not re-evaluated if the
archive is already extracted). So patching the binaries *in those repos* should
work, because the repo rules that create symlinks from them will then point
to patched binaries.

---

## Session 3 (2026-03-03, continued)

### Deep investigation: rules_python internals

Cloned `rules_python` (v1.5.1) locally to study the code.

**Key code paths in rules_python**:

1. `python/private/toolchains_repo.bzl:312-380` - `_host_compatible_python_repo_impl()`
   - Creates `python_3_12_host` repo
   - Symlinks all files from `python_3_12_x86_64-unknown-linux-gnu` (the download)
   - Runs `CheckHostInterpreter`: executes the python binary with a test script
   - This is where the ENOENT error occurs

2. `python/private/python_repository.bzl` - `_python_repository_impl()`
   - Downloads python-build-standalone distribution via `rctx.download_and_extract()`
   - Creates `python` symlink -> `bin/python3`

3. `python/private/local_runtime_repo.bzl` - Alternative that uses system Python
   - Accepts `interpreter_path` (absolute path or PATH lookup)
   - No download, no ELF binary issues
   - Available since rules_python 1.4.0

4. `python/private/pypi/extension.bzl` - `pip.parse()` implementation
   - `_detect_interpreter()` looks for `python_3_12_host` in `INTERPRETER_LABELS`
   - If not found, fails unless `python_interpreter` attr is explicitly provided
   - `python_interpreter` attr accepts a path string (e.g., `/bin/python3`)
   - Merged from `ATTRS` dict in `python/private/pypi/attrs.bzl`

**Options considered for Python**:

| Option | Description | Viable? |
|--------|-------------|---------|
| `local_runtime_repo` | Replace downloaded toolchain entirely | Partial: `pip.parse()` still needs `python_3_12_host` |
| `pip.parse(python_interpreter=...)` | Explicit interpreter for pip | Yes, but `python_3_12_host` failure still blocks analysis |
| patchelf downloaded binary | Fix the ELF interpreter in-place | Best: fixes root cause for ALL downloaded binaries |
| `register_toolchains("@rules_python//python/runtime_env_toolchains:all")` | Minimal toolchain using `/usr/bin/env python3` | Doesn't fix the download |

### Deep investigation: rules_rust cargo-bazel splicing

**Key findings for rules_rust**:

1. `crate.from_cargo()` in MODULE.bazel has NO attributes for custom cargo/rustc paths
2. `splicing_utils.bzl` passes explicit `--cargo` and `--rustc` CLI args to cargo-bazel
   - These paths come from `rust_host_tools` repo (downloaded Rust toolchain)
   - CLI args override any env vars like `CARGO=` or `RUSTC=`
3. `CARGO_BAZEL_GENERATOR_URL` works for the cargo-bazel binary itself
4. But cargo-bazel spawns downloaded `cargo` and `rustc` which are pre-built ELFs

**Root cause**: The `rust_host_tools` repo is a symlink repo (like `python_3_12_host`).
It symlinks from `rust_linux_x86_64__x86_64-unknown-linux-gnu__stable_tools`.
If we patchelf the binaries in the underlying download repo, rust_host_tools
will use the patched versions.

### New strategy: universal patchelf

**Instead of symlinking individual Nix binaries** (fragile, doesn't handle Bazel
repo rule re-evaluation), **patchelf ALL downloaded ELF binaries in the Bazel
cache** after the first fetch.

**How it works**:

1. First `bazel fetch` downloads and extracts all toolchains (Python, Rust, Go,
   LLVM). Fails because the pre-built ELF binaries can't execute.

2. Run `patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 --add-rpath /lib64`
   on every dynamically-linked ELF file under `$HOME/.cache/bazel/_bazel_*/*/external/`
   and `$HOME/.cache/bazel/_bazel_*/*/modextwd/`.

3. Skip files with Nix store interpreters (already correct) or already-patched files.

4. Second `bazel fetch` re-evaluates failed repo rules. The platform-specific
   repos (downloads) are already extracted and now patched. Repo rules like
   `python_3_12_host` and `rust_host_tools` create symlinks to the patched
   binaries, and their validation steps succeed.

**Why patchelf is better than symlink replacement**:

- **Universal**: handles every downloaded binary automatically (Python, cargo,
  rustc, Go, LLVM tools, cargo-bazel, etc.)
- **Survives re-evaluation**: patching modifies the actual downloaded files, not
  the symlink repos that get recreated
- **Preserves binary functionality**: the original binary runs with its own
  libraries (via existing RPATH like `$ORIGIN/../lib`), just with a working
  dynamic linker
- **No version mismatch**: uses the exact versions Bazel expects (Python 3.12,
  Rust 1.86.0, etc.) instead of substituting Nix versions

**New tools added**: `patchelf`, `file`, `findutils` to `nativeBuildInputs`.

**Kept from before**: `CARGO_BAZEL_GENERATOR_URL`, `CARGO`, `RUSTC` env vars
as fallbacks. These help if the patchelf approach doesn't cover cargo-bazel's
splice step (where it invokes cargo/rustc via `--cargo`/`--rustc` CLI args).

### Potential concerns

1. **Python CheckHostInterpreter test**: After patchelf, the downloaded Python
   should execute. The test asserts `Path(sys.executable).resolve()` matches
   `Path("python").resolve()`. Since everything is symlinked correctly and the
   binary runs, this should pass.

2. **Shared library dependencies**: The downloaded Python from
   python-build-standalone may need more libraries than our `fhsLibs` provides
   (e.g., `libreadline`, `libncurses`, `libffi`, `libsqlite3`). The patchelf
   `--add-rpath /lib64` only helps if the library is in `/lib64`. The binary's
   own `$ORIGIN/../lib` RPATH should provide Python-specific libs from the
   extracted distribution.

3. **Bazel sandbox**: If Bazel uses `linux-sandbox` for repo rule execution
   (not just the process wrapper), the `/lib64` mount from bwrap might not be
   visible inside Bazel's nested sandbox. However, repo rules use
   `rctx.execute()` which goes through the process wrapper (not linux-sandbox),
   so this should be fine.

### Patchelf approach result: WRONG APPROACH

**patchelf is not needed.** The downloaded binaries ALREADY have
`/lib64/ld-linux-x86-64.so.2` as their ELF interpreter. Confirmed by examining
a downloaded `cargo` binary:

```
$ readelf -l cargo | grep interpreter
    [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
$ readelf -d cargo | grep NEEDED
    (NEEDED)  libdl.so.2, libgcc_s.so.1, librt.so.1, libpthread.so.0, libm.so.6, libc.so.6
```

All needed libraries (glibc, libgcc_s) are in our `fhsLibs` mounted at `/lib64`.
patchelf correctly skipped these binaries because they already have the right
interpreter.

### Critical discovery: Bazel linux-sandbox creates nested mount namespaces

**The binaries can't execute because Bazel's `linux-sandbox` creates a new mount
namespace** that does NOT inherit bwrap's `/lib64` mount.

**Evidence from Bazel docs** (`site/en/docs/sandboxing.md`):
> linux-sandbox uses Linux Namespaces (User, Mount, PID, Network and IPC
> namespaces) to isolate the action from the host... makes the entire
> filesystem read-only except for the sandbox directory.

This means:
1. We run Bazel inside bwrap, which provides `/lib64` via a bind mount
2. Bazel's `linux-sandbox` creates a NESTED mount namespace
3. The nested namespace starts fresh and only includes paths Bazel explicitly
   maps (source tree, output base, etc.)
4. Our `/lib64` bwrap mount is NOT visible in Bazel's nested namespace
5. When the downloaded binary tries to use `/lib64/ld-linux-x86-64.so.2`,
   the file doesn't exist -> ENOENT

**Subtle point**: The Python error comes from `process-wrapper-legacy.cc:80`
(process wrapper, not linux-sandbox). But the cargo-bazel error comes from
Rust's `std::process::Command` within cargo-bazel itself. Both ultimately
fail because the kernel can't find the ELF interpreter.

**Wait - repo rules use `rctx.execute()`** which goes through the process
wrapper, NOT linux-sandbox. The process wrapper doesn't create mount namespaces.
So `/lib64` from bwrap SHOULD be visible. Need to investigate further.

### Debug build: testing binary execution inside bwrap

Added explicit tests to the build:
- Execute `cargo --version` inside a fresh bwrap namespace (same mounts)
- Execute `python3.12 --version` inside a fresh bwrap namespace
- Check `file` and `readelf` output on the actual downloaded binaries
- Debug listing of all repos that exist after first fetch

This will tell us:
1. Whether the binaries CAN execute in the bwrap namespace at all
2. Whether the issue is bwrap, Bazel sandbox, or missing libraries

Also added `--spawn_strategy=local` and `--sandbox_debug` to Bazel args
to disable Bazel's own sandbox and see more debug info.

### BREAKTHROUGH: bwrap /lib64 mount doesn't work at all!

Debug test revealed the critical issue:
```
=== Testing bwrap /lib64 mount ===
FAILED: /lib64/ld-linux-x86-64.so.2 not found in bwrap!
```

Even a simple `ls` inside a fresh bwrap can't see `/lib64`. The bwrap mount
`--ro-bind ${fhsLibs}/lib /lib64` is silently failing. Both cargo and python
execution inside bwrap also failed.

**Root cause**: The Nix sandbox itself likely prevents bwrap from creating
mount namespaces. bwrap uses `unshare(CLONE_NEWNS)` to create a mount namespace,
but the Nix sandbox may have already used all allowed nested namespaces, or
may be running with restricted `user_namespaces` settings.

**This means the entire bwrap approach has been broken from the start.** Bazel
runs inside bwrap, but bwrap's mounts (including `/lib64`) never actually worked.
Bazel was running in a namespace that looks like it has a fresh root but `/lib64`
was never populated.

**This explains everything**:
- Bash worked because it was bind-mounted to `/bin/bash` (explicit path)
- Bazel itself worked because it's a Nix store binary (has Nix interpreter)
- Downloads and repo resolution worked (no ELF execution needed)
- But ALL pre-built ELF binaries failed (cargo, python, cargo-bazel)

### Corrected strategy: patchelf to Nix store interpreter

Now that we know bwrap mounts don't work, **patchelf IS the correct approach**,
but we need to set the interpreter to the **Nix store glibc path** (not
`/lib64/ld-linux-x86-64.so.2`):

```
patchelf --set-interpreter ${glibc}/lib/ld-linux-x86-64.so.2 \
         --set-rpath ${glibc}/lib:${gcc-unwrapped.lib}/lib:${zlib}/lib:... \
         <binary>
```

This works because `/nix/store/...` paths ARE accessible in the Nix sandbox.

### Fix: patchelf to Nix store paths - WORKS!

Changed patchelf to set interpreter to `${glibc}/lib/ld-linux-x86-64.so.2`
(Nix store path) and RPATH to include `${glibc}/lib:${gcc-unwrapped.lib}/lib:
${zlib}/lib:${openssl.out}/lib:${curl.out}/lib` plus original RPATH.

Verification after patchelf:
```
cargo interpreter: /nix/store/...-glibc-2.42-51/lib/ld-linux-x86-64.so.2
cargo rpath: /nix/store/...-glibc-.../lib:...-zlib-.../lib:$ORIGIN/../lib
cargo test: cargo 1.86.0 (adf9b6ad1 2025-02-28)     <-- SUCCESS!
python interpreter: /nix/store/...-glibc-2.42-51/lib/ld-linux-x86-64.so.2
python test: Python 3.12.11                            <-- SUCCESS!
```

### Remaining issue: Bazel re-creates repos on second fetch

Second fetch progress:
- **Python CheckHostInterpreter: PASSED** - pip now downloads jinja2/jsonschema
- **cargo-bazel splice: FAILED** - `rustc: error while loading shared libraries:
  libz.so.1`

The `rustc` error means Bazel re-created `rust_host_tools` from cached
archives, losing our patchelf changes. The binary has the original
`/lib64/ld-linux-x86-64.so.2` interpreter again.

**Fix**: Multi-pass fetch-patch loop. Run `bazel fetch`, patch, retry, patch,
retry... until fetch succeeds. Each round patches any newly created binaries.

### Multi-pass result: Python SOLVED, Rust needs platform repo patching

The multi-pass approach works for Python (CheckHostInterpreter passes on
attempt 2). But `rustc` in `rust_host_tools` keeps getting `libz.so.1`
error because Bazel re-creates the `rust_host_tools` repo on each fetch
attempt, copying fresh (unpatched) binaries from cached platform archives.

Even though we patch between attempts, the patchelf finds and patches the
`rust_host_tools` binaries, but Bazel immediately re-creates the repo with
fresh copies when the next fetch starts.

**Root cause**: `rust_host_tools` is a repo rule that copies binaries from
Rust platform-specific download repos (e.g.,
`rust_linux_x86_64__x86_64-unknown-linux-gnu__stable_tools`). We need to
patch the binaries in THOSE platform repos, not in `rust_host_tools`.

The platform repos don't appear in the listing because they use a different
naming pattern. Need to also scan under `rules_rust++rust+rust_linux_*`
in the external directory.

**Next steps**:
1. Extend patchelf scan to cover ALL repos under `external/`, including
   platform-specific Rust repos
2. This should already be handled by `patch_elfs "$bazel_cache"` since
   it scans the entire `external/` tree. The issue might be that the
   platform repos store binaries differently (tar archives not yet extracted,
   or in a subdirectory we're not following).

### Current status

Debugging why platform-specific Rust repos aren't getting patchelf'd.
The scan covers `external/` recursively with `-L` (follow symlinks).
