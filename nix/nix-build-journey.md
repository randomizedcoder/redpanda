# Building Redpanda with Nix: A Journey

## 1. Introduction

[Redpanda](https://github.com/redpanda-data/redpanda) is a
high-performance, Kafka-compatible streaming data platform written in
C++ with a Go CLI (`rpk`). It uses Bazel as its build system, the
Seastar framework for thread-per-core async I/O, and downloads
pre-built toolchains (LLVM, Python, Rust, Go) during the build.

This document tells the story of adding Nix support to Redpanda. It
is a learning journal — written as we went, mistakes included — aimed
at anyone curious about making large Bazel projects build under Nix.

**Headline results:**

- `nix build .#rpk` produces a working rpk binary
- `nix develop` drops you into a shell with everything needed for
  development
- Inside that shell, `bazelisk build --config=system-clang
  //src/v/redpanda:redpanda` compiles a fully functional Redpanda
  server — 3,574 actions, 237 MB binary, Kafka produce/consume tested

**What we didn't achieve (yet):** a pure `nix build .#redpanda`. The
Nix sandbox and Bazel's sandbox have a fundamental composition
problem that we'll explain in detail. The dev shell approach works
today; the pure build is parked pending upstream Bazel changes.

We learned a lot along the way and got many things wrong before
getting them right. This document is honest about both.

---

## 2. Quick Start

Three things work today. Each takes a single command.

### Build rpk (the Go CLI)

```bash
nix build .#rpk
./result/bin/rpk version
```

This uses `buildGoModule` — the same pattern as nixpkgs' existing
`redpanda-client` package. No Bazel involved.

### Enter the development shell

```bash
nix develop
```

This gives you bazelisk, clang 20, lld, Python 3.12, JDK, and every
other tool needed to build Redpanda. A `.bazelrc.nix` is generated
automatically by the shell hook.

### Build the C++ server (inside the dev shell)

```bash
nix develop --command \
  bazelisk build --config=system-clang //src/v/redpanda:redpanda
```

The first build takes around 30 minutes (1,770 seconds on an 8-core
machine). Incremental rebuilds are fast thanks to Bazel's action
cache.

---

## 3. Objective

We set out to do three things:

1. **rpk** — build the Go CLI with Nix (straightforward)
2. **Dev shell** — provide a `nix develop` environment for daily work
3. **redpanda** — build the C++ server binary

For the C++ server, we explored two approaches:

| Approach | Description | Status |
|----------|-------------|--------|
| **Dev shell + Bazel** | Nix provides the environment; Bazel builds inside it | Working |
| **Pure `nix build`** | Nix drives the entire build, including Bazel fetch | Blocked |

The pure build is the "right" answer for CI and reproducibility, but
the dev shell approach is what we shipped.

---

## 4. What We Achieved

| Component | Status | Command |
|-----------|--------|---------|
| rpk (Go CLI) | **Working** | `nix build .#rpk` |
| Dev shell | **Working** | `nix develop` |
| redpanda via dev shell | **Working** | `bazelisk build --config=system-clang //src/v/redpanda:redpanda` |
| redpanda via `nix build` | **Blocked** | Fundamental sandbox composition problem |

---

## 5. The Sandbox Composition Problem

To understand why a pure `nix build` is hard, you need to understand
how Nix and Bazel sandbox differently. (For the full technical deep
dive, see `sandboxing-build-systems-nix-and-bazel.md`.)

**Nix uses an allowlist model.** It starts with an empty filesystem
and bind-mounts only declared inputs. There is no `/lib64`, no
`/usr`, no `/bin` (except `/bin/sh`). Binaries must use Nix store
paths for their ELF interpreter (the dynamic linker).

**Bazel uses a denylist model.** It starts with the full filesystem
and makes most of it read-only. It assumes a standard Linux FHS
layout — `/lib64/ld-linux-x86-64.so.2` exists, `/usr/bin/env` exists.

**Bazel downloads pre-built FHS binaries.** Rules like `rules_python`,
`rules_rust`, `rules_go`, and `toolchains_llvm` all download pre-built
toolchain binaries. These binaries have a hardcoded ELF interpreter:

```
$ readelf -l python3.12 | grep interpreter
    [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
```

Inside Nix's sandbox, `/lib64` does not exist. The kernel returns
`ENOENT` — not because the binary is missing, but because the
**dynamic linker it requests** is missing.

**The critical gap: no hook between download and execute.** Bazel's
repository rules call `repository_ctx.download_and_extract()` and
then immediately `repository_ctx.execute()` on the result. There is
no interception point where we could `patchelf` the binary before
first use. We confirmed this by reading the Bazel source: the code
path goes `repository_ctx.execute()` → Java `Command` →
`Runtime.exec()` with no wrapper.

This is the fundamental reason a pure `nix build .#redpanda` is
blocked today.

---

## 6. The Pure Nix Build Attempt

We spent significant time trying to make `nix build .#redpanda` work.
The code is in `nix/redpanda.nix` (435 lines) and represents our best
attempt before we understood the composition problem fully.

### The approach: two-phase FOD build

1. **Phase 1 (FOD):** A fixed-output derivation runs `bazel fetch`
   with network access. The output hash locks all dependencies.
2. **Phase 2:** A normal derivation runs `bazel build` offline with
   the cached repository from Phase 1.

FOD stands for "fixed-output derivation" — a Nix derivation whose
output is identified by content hash rather than build process. Nix
grants FODs network access (no `CLONE_NEWNET`), which is how
`bazel fetch` can download dependencies.

### What we tried

**bubblewrap (bwrap):** We wrapped Bazel inside bwrap to mount
`/lib64` for the pre-built ELF binaries. Discovery: bwrap's mount
namespaces silently fail inside the Nix sandbox. The Nix sandbox root
is read-only; `unshare(CLONE_NEWNS)` from bwrap doesn't create
effective bind mounts. The `/lib64` overlay never actually existed.

**patchelf:** We patched downloaded binaries to use Nix store paths
for the interpreter (`patchelf --set-interpreter
/nix/store/...-glibc/lib/ld-linux-x86-64.so.2`). This worked
perfectly — `cargo 1.86.0` and `Python 3.12.11` both ran after
patching. But Bazel **re-creates repo rules** on each fetch,
overwriting our patches with fresh copies from cached archives. A
multi-pass fetch/patch loop partially worked but was fragile.

### Why this is parked

The core problem is that Bazel downloads and immediately executes
ELF binaries with no interception point. We explored a Bazel fork
(`nixify` branch) that would add a post-extract hook, but decided
the dev shell approach was more practical for now.

The `nix/redpanda.nix` code remains in the repository as a reference.
If Bazel adds a `--repo_post_extract_command` flag or similar, the
FOD approach becomes viable with minimal changes.

---

## 7. The Dev Shell Build: Challenges and Solutions

Building Redpanda in the dev shell required solving 17 distinct issues
across 6 files. This section documents every one.

### 7a. Summary Table

| # | Category | Error | File Changed | Fix |
|---|----------|-------|-------------|-----|
| 1 | Toolchain | `@local_config_cc_toolchains` not visible | `MODULE.bazel` | Add `cc_configure_extension` + `use_repo` |
| 2 | Toolchain | `py3_runtime.interpreter` is `None` | `expand_with_stamp_vars.bzl` | Guard nullable interpreter |
| 3 | Shell | `execvp(/bin/bash)` fails | `.bazelrc.nix` | `--shell_executable=$(which bash)` |
| 4 | Shell | `#!/bin/bash` in rules_python | `stage1_bootstrap_template.sh` | Change to `#!/usr/bin/env bash` |
| 5 | PATH | `env: 'bash': No such file or directory` | `.bazelrc.nix` | `--action_env=PATH=$PATH` |
| 6 | Env | `use_default_shell_env = False` blocks scripts | `expand_with_stamp_vars.bzl`, `pbgen.bzl` | Set to `True` |
| 7 | Linking | `ld.lld: unable to find library -lc++` | `.bazelrc.nix` | Pass NIX_* env vars + LIBRARY_PATH |
| 8 | Foreign | krb5 configure fails (libcrypto.so.3) | `krb5.BUILD` | `LD_LIBRARY_PATH` in env dict |
| 9 | Foreign | libxml2 autogen (missing pkg.m4) | `.bazelrc.nix` | `--action_env=ACLOCAL_PATH` |
| 10 | Linking | protoc_minimal can't find libstdc++.so.6 | `.bazelrc.nix` | GCC lib in LD_LIBRARY_PATH |
| 11 | Stdlib | Seastar `future.hh` wrong stdlib headers | `shell.nix` | Switch to `libcxxClang` |
| 12 | Linking | Exec-config tools can't find libc++.so.1 | `.bazelrc`, `.bazelrc.nix` | `--host_linkopt -stdlib=libc++` + suppress ProtocAuthenticityCheck |
| 13 | Headers | `xfs/linux.h` not found | `shell.nix` | Add `xfsprogs` |
| 14 | Runtime | protoc Exit 127 (libc++.so.1 missing) | `pbgen.bzl` | `use_default_shell_env = True` |
| 15 | Nix | `xfsprogs` undefined variable | `shell.nix` | Add to function parameters |
| 16 | Headers | `valgrind/valgrind.h` not found | `shell.nix` | Add `valgrind` |
| 17 | Runtime | protoc libc++.so.1 still failing | `.bazelrc.nix` | RPATH flags (`--linkopt=-Wl,-rpath,...`) |

### 7b. Grouped Narrative

#### Toolchain visibility (Issues 1–2)

**Issue 1: `@local_config_cc_toolchains` not visible under Bzlmod.**

Redpanda's `.bazelrc` has a `system-clang` configuration that
references `@local_config_cc_toolchains//:all`. Under Bzlmod, this
repository is created by the `cc_configure_extension` module
extension from `rules_cc`, but only `rules_cc` itself had called
`use_repo` on it — the main module couldn't see it.

Error:
```
No repository visible as '@local_config_cc_toolchains' from main repository
```

Fix in `MODULE.bazel` (after the `rules_cc` dep):

```starlark
cc_configure = use_extension(
    "@rules_cc//cc:extensions.bzl", "cc_configure_extension")
use_repo(cc_configure, "local_config_cc_toolchains")
```

**Issue 2: `py3_runtime.interpreter` is `None` for local Python.**

The `expand_with_stamp_vars` rule in
`src/v/version/expand_with_stamp_vars.bzl` accessed
`toolchain.py3_runtime.interpreter` directly in its `tools` list.
For our local Python toolchain (which uses `interpreter_path` — a
string pointing to the Nix store — instead of `interpreter` — a
Bazel File object), this attribute is `None`.

Error:
```
expected value of type 'File' for a member of parameter 'tools'
but got NoneType
```

Fix: guard the nullable value:

```python
interpreter = toolchain.py3_runtime.interpreter
tools = [ctx.executable._tool] + ([interpreter] if interpreter else [])
```

#### Shell and PATH (Issues 3–5)

**Issue 3: NixOS has no `/bin/bash`.**

Bazel's process wrapper and genrules use `/bin/bash`. NixOS provides
`/bin/sh` and `/usr/bin/env` as FHS compatibility paths, but not
`/bin/bash`.

Error:
```
process-wrapper-legacy.cc:80: "execvp(/bin/bash, ...)":
No such file or directory
```

Fix: the shell hook in `nix/shell.nix` generates `.bazelrc.nix` with:
```
build --shell_executable=/nix/store/...-bash-5.3p9/bin/bash
```

**Issue 4: `#!/bin/bash` in rules_python bootstrap script.**

The `stage1_bootstrap_template.sh` in rules_python uses `#!/bin/bash`
as its shebang. `--shell_executable` doesn't help because the shebang
is baked into the generated script.

Fix: changed `#!/bin/bash` to `#!/usr/bin/env bash` in the patched
rules_python. (This should be upstreamed — NixOS and Guix both need
it.)

**Issue 5: Sandbox PATH doesn't include Nix store paths.**

Even with `--shell_executable` pointing at Nix bash, scripts inside
Bazel actions couldn't find tools because the sandbox PATH doesn't
include Nix store paths. The `#!/usr/bin/env bash` from Issue 4
requires `bash` to be on PATH.

Fix: propagate the Nix PATH into actions via `.bazelrc.nix`:
```
build --action_env=PATH=$PATH
build --host_action_env=PATH=$PATH
```

**Trade-off:** this breaks build hermeticity — actions can see all
tools on the host PATH. Acceptable for a dev shell, not ideal for CI.

#### Library linking (Issues 7, 10–12, 17)

These five issues all relate to the same theme: making the Nix clang
wrapper and the Nix store libraries work inside Bazel's action
sandbox.

**Issue 7: `ld.lld: unable to find library -lc++`.**

The `system-clang` config uses `-fuse-ld=lld`, which calls lld
directly — bypassing the Nix `ld` wrapper that would normally inject
`-L` paths from `NIX_LDFLAGS`.

Fix: pass all `NIX_*` environment variables through to Bazel actions
and set `LIBRARY_PATH` as a fallback. The shell hook generates:
```
build --action_env=NIX_LDFLAGS
build --action_env=NIX_CC
build --action_env=NIX_BINTOOLS
...
build --action_env=LIBRARY_PATH=/nix/store/.../libcxx/lib:/nix/store/.../gcc/lib
```

**Issue 10: `protoc_minimal` can't find `libstdc++.so.6`.**

Exec-config binaries (tools that run during the build, like protoc)
use the auto-detected CC toolchain, which links against libstdc++ from
GCC. The dynamic linker can't find `libstdc++.so.6` because the GCC
lib directory is in the Nix store, not a standard system path.

Fix: include GCC's lib directory alongside libc++ in
`LD_LIBRARY_PATH`:
```nix
gccLib = stdenv.cc.cc.lib;
# in .bazelrc.nix:
build --action_env=LD_LIBRARY_PATH=<libcxx-path>:<gcc-lib-path>
```

**Issue 11: Seastar `future.hh` fails — wrong stdlib headers.**

This was a subtle one. After fixing all the linking issues, the build
progressed to 2,751 sandbox processes before hitting a C++ compilation
error in Seastar's `future.hh`.

The root cause: we were using `llvmPackages_20.clang` (the default Nix
clang wrapper), which uses **libstdc++ headers** from GCC. Redpanda
expects **libc++ headers**. Seastar's `future.hh` has `#ifdef
__GLIBCXX__` conditional code paths that make optimization shortcuts
specific to libstdc++ internals. Compiling with the wrong stdlib
headers caused template instantiation failures.

Nix provides multiple clang wrapper variants:

| Package | C++ stdlib | Nix clang wrapper sets |
|---------|-----------|----------------------|
| `llvmPackages_20.clang` | libstdc++ (GCC) | `-cxx-isystem .../gcc/include/c++` |
| `llvmPackages_20.libcxxClang` | libc++ | `-cxx-isystem .../libcxx-dev/include/c++/v1` |

Fix: switched `nix/shell.nix` from `clang` to `libcxxClang`. We
initially also tried adding `--cxxopt=-stdlib=libc++` to `.bazelrc`,
but the Nix wrapper already handles include paths — adding the flag
explicitly caused clang to report "argument unused during compilation"
which is fatal under Redpanda's `-Werror`.

**Issue 12: Exec-config tools can't find `libc++.so.1` at runtime.**

After the Seastar fix, exec-config binaries like `protoc-gen-upb` and
`protoc` were dynamically linked against libc++ but couldn't find
`libc++.so.1` in the Bazel sandbox.

The `toolchains_llvm` hermetic toolchain avoids this by statically
linking libc++ (`-l:libc++.a -l:libc++abi.a`). We tried static
linking too, but it caused duplicate symbol errors in the ragel build
— both `libstdc++.a` (from the Nix wrapper's `NIX_LDFLAGS`) and
`libc++.a` (from our flag) were being linked.

Fix (two parts):

1. Dynamic libc++ for exec config:
   ```
   build:system-clang --host_linkopt -stdlib=libc++
   build:system-clang --host_linkopt --unwindlib=libgcc
   ```

2. Suppress `ProtocAuthenticityCheck` — a protobuf rule that uses
   `ctx.actions.run_shell()` without `use_default_shell_env = True`,
   giving it a minimal environment where `grep` and
   `LD_LIBRARY_PATH` aren't available:
   ```
   build --@protobuf//bazel/toolchains:allow_nonstandard_protoc
   ```

**Issue 17: protoc `libc++.so.1` — the final RPATH fix.**

Even after `use_default_shell_env = True` in `pbgen.bzl` (Issue 14)
and `--action_env=LD_LIBRARY_PATH`, protoc still failed with Exit 127.
The environment variable propagation through Bazel's
`processwrapper-sandbox` was unreliable for `ctx.actions.run()` actions.

Fix: embed the library paths directly in the binary via RPATH:
```
build --linkopt=-Wl,-rpath,/nix/store/.../libcxx/lib
build --linkopt=-Wl,-rpath,/nix/store/.../gcc/lib
build --host_linkopt=-Wl,-rpath,/nix/store/.../libcxx/lib
build --host_linkopt=-Wl,-rpath,/nix/store/.../gcc/lib
```

RPATH is baked into the ELF binary at link time. The dynamic linker
uses it unconditionally — no environment variable propagation needed.
This is the dynamic-linking equivalent of `toolchains_llvm`'s static
libc++ approach, and it was the fix that finally made the full build
succeed.

#### Foreign builds (Issues 8–9)

**Issue 8: krb5 `configure` fails — libcrypto.so.3 not found.**

The krb5 `rules_foreign_cc` build runs autoconf's `AC_CHECK_SIZEOF`
which compiles AND executes a test program. The test program links
against OpenSSL (`-lcrypto`) which was built by another
`rules_foreign_cc` target. Linking works (the `-L` path is correct),
but at runtime the test binary's RPATH doesn't include the staging
directory where `libcrypto.so.3` lives.

Fix in `bazel/thirdparty/krb5.BUILD` — added `LD_LIBRARY_PATH` to the
`env` dict using `$$EXT_BUILD_DEPS` (a `rules_foreign_cc` variable):

```python
env = {
    ...
    "LD_LIBRARY_PATH": "$$EXT_BUILD_DEPS/openssl_foreign_cc/lib",
},
```

**Issue 9: libxml2 autogen — missing `pkg.m4`.**

The libxml2 `rules_foreign_cc` build runs `autoreconf` which needs
`pkg.m4` from `pkg-config`. Nix sets `ACLOCAL_PATH` in the shell
(pointing to automake, libtool, bison, and pkg-config aclocal
directories), but it wasn't propagated into Bazel actions.

Fix: the shell hook adds to `.bazelrc.nix`:
```
build --action_env=ACLOCAL_PATH=$ACLOCAL_PATH
```

#### Missing system headers (Issues 13, 15–16)

**Issue 13: `xfs/linux.h` not found.**

Seastar includes `<xfs/linux.h>` for XFS ioctl support. This header
comes from the xfsprogs development package. Redpanda's standard
build gets it from the Docker sysroot; the Bazel BUILD has no explicit
dependency.

Fix: add `xfsprogs` to `nix/shell.nix` packages.

**Issue 15: `xfsprogs` undefined variable.**

A Nix gotcha: we added `xfsprogs` to the `packages` list but forgot
to add it to the function parameters at the top of `shell.nix`. With
`callPackage`-style Nix files, every package referenced in the body
must appear in the argument list — there is no implicit scope. The
shell failed to evaluate, so `.bazelrc.nix` was never regenerated,
and the build ran with a stale environment from a previous session.

**Issue 16: `valgrind/valgrind.h` not found.**

Seastar unconditionally includes `<valgrind/valgrind.h>` in
`src/core/thread.cc` and `src/core/linux-aio.cc` (no `#ifdef` guard).

Fix: add `valgrind` to both the function parameters and packages list
in `nix/shell.nix`. Nix's stdenv setup hooks propagate the `dev`
output's include path into `NIX_CFLAGS_COMPILE`, which the Nix clang
wrapper injects as `-isystem` flags.

#### Protobuf (Issues 6, 14, 12b)

**Issue 6: `use_default_shell_env = False` blocks script execution.**

The `expand_with_stamp_vars` rule and the `RedpandaProtoGen` rule
both had `use_default_shell_env = False` (or didn't set it, which
defaults to `False`). This gave an empty environment to actions. The
rules_python bootstrap and protoc need at least a functional PATH.

Fix: set `use_default_shell_env = True` in both
`src/v/version/expand_with_stamp_vars.bzl` and
`bazel/pbgen/pbgen.bzl`.

**Issue 14: protoc Exit 127 — `libc++.so.1` not found.**

The `RedpandaProtoGen` rule in `pbgen.bzl` invokes protoc via
`ctx.actions.run()`. Without `use_default_shell_env = True`, the
protoc binary couldn't find `libc++.so.1`. Adding
`use_default_shell_env = True` was necessary but not sufficient —
Issue 17 (RPATH) was the complete fix.

**Issue 12b: `ProtocAuthenticityCheck` fails.**

Protobuf's `ProtocAuthenticityCheck` rule uses
`ctx.actions.run_shell()` without `use_default_shell_env = True`. It
gets a minimal environment without `grep` or library paths.

Fix: suppress with `.bazelrc.nix`:
```
build --@protobuf//bazel/toolchains:allow_nonstandard_protoc
```

---

## 8. The rules_python Patch

### Why it's needed

Bazel's `rules_python` unconditionally downloads a pre-built CPython
binary when `python.toolchain()` is used in MODULE.bazel. In a Nix
environment, `python3` is already on PATH with correct Nix store ELF
paths. If Bazel used this Python instead of downloading one, no
patching or FHS compatibility would be needed.

rules_python v1.5.1 already has a `local_runtime_repo` mechanism that
discovers a system Python via PATH lookup — but it was only available
for legacy WORKSPACE files, not through the MODULE.bazel extension.

### What the patch does

The patch modifies a single file (`python/private/python.bzl`) to
expose the existing `local_runtime_repo` mechanism through the
`python` module extension. Four changes, 70 lines total:

1. **New imports** (2 lines): `local_runtime_repo` and
   `local_runtime_toolchains_repo`
2. **Processing logic** (19 lines): iterate `local_toolchain` tags,
   create a `local_runtime_repo` + `local_runtime_toolchains_repo`
   for each
3. **New tag class** (47 lines): `_local_toolchain` with
   `interpreter_path`, `python_version`, and `on_failure` attributes
4. **Registration** (2 lines): add to `tag_classes` dict, add `PATH`
   to `environ`

### Usage in MODULE.bazel

```starlark
python = use_extension(
    "@rules_python//python/extensions:python.bzl", "python",
    dev_dependency = True)
python.toolchain(
    ignore_root_user_error = True,
    is_default = True,
    python_version = "3.12",
)
python.local_toolchain(
    python_version = "3.12",
    interpreter_path = "python3",
)
use_repo(python, "local_python_3_12", "local_python_3_12_toolchains")
register_toolchains("@local_python_3_12_toolchains//:all")
```

The `python.toolchain()` stays for non-Nix builds (it provides the
download-based fallback). The local toolchain takes precedence when a
local Python is found via `register_toolchains` ordering. When no
local Python is found (e.g., CI without Nix), `on_failure = "warn"`
generates an incompatible-platform stub and the downloaded toolchain
is used instead.

Currently consumed via `local_path_override` in MODULE.bazel. Longer
term, this should become a `git_override` or ideally an upstream
contribution to rules_python.

For the full technical details, see `rules-python-local-toolchain-patch.md`.

---

## 9. File-by-File Change Reference

### New Nix infrastructure files

| File | Lines | Purpose |
|------|-------|---------|
| `flake.nix` | 50 | Root flake: packages (rpk, redpanda), devShell, checks |
| `nix/rpk.nix` | 56 | Go CLI build using `buildGoModule` |
| `nix/shell.nix` | 96 | Dev shell: bazelisk, LLVM 20 (`libcxxClang`), Python, JDK, etc. Shell hook generates `.bazelrc.nix` |
| `nix/redpanda.nix` | 435 | Pure `nix build` attempt (two-phase FOD, bwrap, patchelf) — blocked |
| `nix/bcr.nix` | 11 | Pinned Bazel Central Registry snapshot |
| `.bazelrc.nix` | (generated) | Created by shell hook; Nix-specific Bazel settings (shell_executable, PATH, NIX_* env, RPATH flags) |
| `.gitignore` | +1 line | Ignore `.bazelrc.nix` |

### Modified upstream files

| File | Change |
|------|--------|
| `MODULE.bazel:42-43` | Add `cc_configure_extension` + `use_repo(cc_configure, "local_config_cc_toolchains")` for system-clang visibility |
| `MODULE.bazel:50-53,75-86` | `local_path_override` for patched rules_python; `python.local_toolchain()` + `register_toolchains` |
| `.bazelrc:27-31` | system-clang config: `--host_linkopt -stdlib=libc++`, `--host_linkopt --unwindlib=libgcc`, `--host_linkopt -fuse-ld=lld` |
| `.bazelrc:332` | `try-import %workspace%/.bazelrc.nix` |
| `src/v/version/expand_with_stamp_vars.bzl:10-28` | Guard nullable `py3_runtime.interpreter`; `use_default_shell_env = True`; use File object for executable |
| `bazel/pbgen/pbgen.bzl:148` | Add `use_default_shell_env = True` to `RedpandaProtoGen` action |
| `bazel/thirdparty/krb5.BUILD:60-63` | Add `LD_LIBRARY_PATH=$$EXT_BUILD_DEPS/openssl_foreign_cc/lib` to env |

### Documentation files

| File | Description |
|------|-------------|
| `nix/STATUS.md` | Architecture and status overview |
| `nix/progress_log.md` | Detailed session-by-session log of discoveries |
| `nix/sandboxing-build-systems-nix-and-bazel.md` | Deep dive on Nix vs Bazel sandbox internals |
| `nix/rules-python-local-toolchain-patch.md` | rules_python patch documentation |
| `nix/toolchains-llvm-local-toolchain.md` | LLVM toolchain investigation + full implementation log |
| `nix/nix-build-journey.md` | This document |

---

## 10. Build Results and End-to-End Testing

### Build statistics

```
Target //src/v/redpanda:redpanda up-to-date:
  bazel-bin/src/v/redpanda/redpanda
INFO: Elapsed time: 1770.846s, Critical Path: 552.29s
INFO: 3574 processes: 5012 action cache hit, 104 internal,
      3470 processwrapper-sandbox.
INFO: Build completed successfully, 3574 total actions
```

- **Total time:** 1,770 seconds (~30 minutes)
- **Actions executed in sandbox:** 3,470
- **Action cache hits:** 5,012
- **Binary size:** 237 MB
- **Linked against:** Nix glibc (`/nix/store/...-glibc-2.42-51`)

### Binary verification

```
$ file bazel-bin/src/v/redpanda/redpanda
ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV),
dynamically linked, interpreter /nix/store/...-glibc-2.42-51/lib/
ld-linux-x86-64.so.2, for GNU/Linux 3.10.0, not stripped

$ nix develop --command bazel-bin/src/v/redpanda/redpanda --version
v0.0.0-dev - 0000000000000000000000000000000000000000
```

### End-to-end test results

| Test | Result |
|------|--------|
| Binary exists and is valid ELF | Pass |
| `--version` reports dev version | Pass |
| `--help` shows all Redpanda + Seastar options | Pass |
| Single-node cluster starts (`--smp 1 --memory 512M`) | Pass |
| Admin API `/v1/cluster/health_overview` returns `is_healthy: true` | Pass |
| Admin API `/v1/brokers` shows 1 active broker | Pass |
| Kafka topic creation (`test-nix-build`) | Pass |
| Kafka produce (5 messages) | Pass |
| Kafka consume (5 messages) | Pass |

### Kafka test code

The Kafka test used `kafka-python-ng` (included in the dev shell):

```python
from kafka import KafkaProducer, KafkaConsumer
from kafka.admin import KafkaAdminClient, NewTopic

admin = KafkaAdminClient(bootstrap_servers='127.0.0.1:9092')
admin.create_topics([NewTopic(
    'test-nix-build', num_partitions=1, replication_factor=1)])

producer = KafkaProducer(bootstrap_servers='127.0.0.1:9092')
for i in range(5):
    producer.send('test-nix-build',
                  value=f'hello from nix build #{i}'.encode())
producer.flush()

consumer = KafkaConsumer(
    'test-nix-build', bootstrap_servers='127.0.0.1:9092',
    auto_offset_reset='earliest', consumer_timeout_ms=5000)
for msg in consumer:
    print(f'Consumed: {msg.value.decode()}')
```

Output:
```
Produced 5 messages
  Consumed: hello from nix build #0
  Consumed: hello from nix build #1
  Consumed: hello from nix build #2
  Consumed: hello from nix build #3
  Consumed: hello from nix build #4
Total consumed: 5 messages
```

---

## 11. Design Insights

These are the things we learned that we wish we'd known from the
start.

### RPATH > LD_LIBRARY_PATH in Bazel sandbox

Relying on `LD_LIBRARY_PATH` propagation through Bazel actions is
fragile. Different action types (`ctx.actions.run()` vs
`ctx.actions.run_shell()`), different configurations (target vs exec),
and sandbox implementations can all interfere. RPATH is baked into the
binary at link time and works unconditionally. For a Nix dev shell
where all library paths are stable Nix store paths, RPATH is the
correct approach.

### libcxxClang vs clang — Nix wrapper variants matter

nixpkgs provides multiple clang wrapper variants per LLVM version.
The default (`llvmPackages_20.clang`) uses libstdc++ headers from
GCC. For Redpanda, which requires libc++, you need
`llvmPackages_20.libcxxClang`. Both wrap the same underlying
`clang-20.1.8` binary — the difference is which `-cxx-isystem` paths
the wrapper injects.

### system-clang was already most of the way there

Redpanda's `.bazelrc` already had a `system-clang` configuration that
bypasses `toolchains_llvm` and uses Bazel's built-in CC auto-detection.
This config does most of the heavy lifting. The main additions needed
were: `--host_linkopt -stdlib=libc++` (for exec-config tools),
`--host_linkopt --unwindlib=libgcc`, and the Nix environment variable
propagation.

### Nix multi-output packages need care

Many nixpkgs packages split outputs (e.g., `xfsprogs` has `bin`,
`dev`, `out`, `doc`, `man`). When listed in `mkShell.packages`,
Nix's stdenv setup hooks automatically select the `dev` output and
propagate its include paths into `NIX_CFLAGS_COMPILE`. This works
transparently — but only if the package is actually in scope (in the
`callPackage` function arguments). Missing an argument causes a Nix
evaluation error, not a runtime error.

### Nix and Bazel are complementary, not competing

The deeper insight from this work: Nix excels at deterministic,
content-addressed package management and environment provisioning.
Bazel excels at fast incremental builds with fine-grained caching. A
combination where Nix provides toolchains and Bazel orchestrates
builds is more powerful than either system alone. The dev shell
approach is exactly this combination.

---

## 12. Known Limitations

### PATH hermeticity leak

The `--action_env=PATH=$PATH` propagates the entire host PATH into
build actions. This breaks build hermeticity — actions can see tools
that aren't declared dependencies. A minimal PATH containing only the
necessary Nix store paths would be more hermetic. The shell hook could
construct this by filtering `$PATH` to Nix store entries only.

### local_path_override for rules_python

The patched rules_python is consumed via `local_path_override` in
MODULE.bazel, pointing to `/home/das/Downloads/rules_python`. This is
a local-machine path. For others to use this, it needs to become a
`git_override` pointing at a fork, or ideally the patch should be
contributed upstream.

### aarch64 env var hardcoding

The `NIX_CC_WRAPPER_TARGET_HOST_*` and `NIX_BINTOOLS_WRAPPER_TARGET_HOST_*`
environment variables in `.bazelrc.nix` are hardcoded to
`x86_64_unknown_linux_gnu`. The flake supports `aarch64-linux` in its
system list, but the shell hook would need to be made
architecture-aware (using `aarch64_unknown_linux_gnu` on ARM).

### ProtocAuthenticityCheck suppressed

The `--@protobuf//bazel/toolchains:allow_nonstandard_protoc` flag
disables protobuf's protoc authenticity check. This is a minor
security/integrity trade-off. The check fails because it uses
`ctx.actions.run_shell()` without `use_default_shell_env = True`,
so `grep` and library paths aren't available.

### nix build .#redpanda blocked

The pure `nix build .#redpanda` derivation (in `nix/redpanda.nix`) is
blocked by the sandbox composition problem described in Section 5.
This remains the case until Bazel adds a mechanism to intercept
binary execution in repository rules (e.g., a
`--repo_post_extract_command` flag).

---

## 13. Clearing Caches and Measuring Build Time

If you want a clean-room build measurement, you need to clear both
Bazel's and Nix's caches.

### Clear Bazel caches

```bash
# Remove Bazel output base, action cache, and repository cache
bazelisk clean --expunge
```

This deletes everything under `~/.cache/bazel/_bazel_*/`. The next
build will re-fetch all external dependencies and rebuild from
scratch.

### Clear Nix caches

```bash
# Remove old Nix generations (frees store paths no longer referenced)
nix-collect-garbage -d

# Garbage-collect unreferenced store paths
nix store gc
```

Note: `nix store gc` only removes store paths not referenced by any
GC root. If `./result` symlinks or flake lock entries reference
packages, they won't be collected until those roots are removed.

### Full clean rebuild with timing

```bash
# 1. Clear Bazel
bazelisk clean --expunge

# 2. Enter dev shell and build with timing
nix develop --command bash -c \
  'time bazelisk build --config=system-clang //src/v/redpanda:redpanda'
```

Our reference build (8-core machine, NVMe SSD):
- **Total:** 1,770 seconds (29.5 minutes)
- **Critical path:** 552 seconds (9.2 minutes)
- **Actions:** 3,574 total, 3,470 in sandbox

### Incremental rebuild notes

After the initial build, incremental rebuilds are fast. If you change
a single `.cc` file, only the affected compilation unit and its
dependents need to rebuild. Bazel's action cache (`5,012 cache hits`
in our build) handles this automatically.

The `.bazelrc.nix` is regenerated every time you enter `nix develop`.
If you change `nix/shell.nix` (e.g., add a package or change LLVM
version), you need to re-enter the shell to regenerate it. Bazel will
detect the changed flags and invalidate affected actions.

---

## 14. References

### In this repository

- `nix/STATUS.md` — architecture overview and current status
- `nix/progress_log.md` — detailed session log of discoveries
- `nix/sandboxing-build-systems-nix-and-bazel.md` — deep dive on
  sandbox internals (1,400 lines)
- `nix/rules-python-local-toolchain-patch.md` — rules_python patch
- `nix/toolchains-llvm-local-toolchain.md` — LLVM investigation +
  full issue-by-issue implementation log

### External

- [Nix sandbox source](https://github.com/NixOS/nix/blob/master/src/libstore/unix/build/linux-derivation-builder.cc)
- [Bazel sandbox source](https://github.com/bazelbuild/bazel/blob/master/src/main/tools/linux-sandbox-pid1.cc)
- [rules_python local_runtime_repo](https://github.com/bazelbuild/rules_python/blob/main/python/private/local_runtime_repo.bzl)
- [Redpanda](https://github.com/redpanda-data/redpanda)
