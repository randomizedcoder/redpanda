# Using Nix-Provided LLVM with toolchains_llvm

## Context

Following the same approach as the `rules_python` patch (see
`rules-python-local-toolchain-patch.md`), we investigated whether
`toolchains_llvm` can be made to use a Nix-provided LLVM instead of
downloading pre-built FHS binaries.

**Key discovery: no patch to toolchains_llvm is needed.**

Unlike `rules_python`, which had no MODULE.bazel mechanism for using a system
Python, `toolchains_llvm` already has first-class support for pointing at a
local LLVM distribution via the `llvm.toolchain_root()` tag class.

## The Problem (same as rules_python)

Redpanda's MODULE.bazel configures two LLVM toolchains (lines 191–232):

```starlark
llvm.toolchain(
    name = "current_llvm_toolchain",
    llvm_version = "20.1.8",
    urls = {
        "linux-x86_64": ["https://github.com/redpanda-data/llvm-project/releases/..."],
        ...
    },
    sha256 = { ... },
)
```

This downloads a pre-built LLVM tarball from `redpanda-data/llvm-project`
releases — an FHS binary with `/lib64/ld-linux-x86-64.so.2` as its ELF
interpreter. Inside a Nix build sandbox, this binary cannot execute.

## What Already Exists in toolchains_llvm

### `llvm.toolchain_root()` tag class

**File:** `toolchain/extensions/llvm.bzl`, lines 110–117

```starlark
"toolchain_root": tag_class(
    attrs = {
        "name": attr.string(doc = "Same name as the toolchain tag."),
        "targets": attr.string_list(doc = "Specific targets, if any."),
        "label": attr.label(doc = "Dummy label whose package path is the root."),
        "path": attr.string(doc = "Absolute path to the toolchain root."),
    },
),
```

When `path` is set to an absolute path (starts with `/`), the toolchain
skips downloading and uses the system LLVM directly:

**File:** `toolchain/internal/configure.bzl`, lines 80–103

```python
if not rctx.attr.toolchain_roots:
    toolchain_root = "@%s_llvm//" % rctx.attr.name  # downloaded repo
else:
    _, toolchain_root = _exec_os_arch_dict_value(rctx, "toolchain_roots")

system_llvm = False
if _is_absolute_path(toolchain_root):
    use_absolute_paths_llvm = True
    system_llvm = True

if system_llvm:
    llvm_dist_path_prefix = _canonical_dir_path(toolchain_root)
```

This is already used in toolchains_llvm's own test suite:

**File:** `tests/MODULE.bazel`, lines 145–157

```starlark
llvm.toolchain(
    name = "llvm_toolchain_with_system_llvm",
    llvm_versions = {"": "16.0.0"},
)
llvm.toolchain_root(
    name = "llvm_toolchain_with_system_llvm",
    path = "/opt/llvm-16",
)
```

### Expected directory layout

toolchains_llvm expects a single directory containing `bin/` with these tools
(**file:** `toolchain/internal/common.bzl`, lines 38–55):

```
<root>/
  bin/
    clang-cpp
    clang-format
    clang-tidy
    clangd
    ld.lld
    llvm-ar
    llvm-dwp
    llvm-profdata
    llvm-cov
    llvm-nm
    llvm-objcopy
    llvm-objdump
    llvm-strip
  lib/
    clang/<version>/include/    # compiler headers
  include/
    c++/v1/                     # libc++ headers (if using libc++)
```

Additionally, the cc_toolchain_config looks for `clang` (the compiler driver)
at `<root>/bin/clang` via a `cc_wrapper.sh` that references it by path
(**file:** `toolchain/internal/configure.bzl`, lines 524–532).

### Redpanda's existing system-clang config

Redpanda's `.bazelrc` (lines 27–37) already has an alternative `system-clang`
configuration that bypasses `toolchains_llvm` entirely:

```bazelrc
build:system-clang --extra_toolchains=@local_config_cc_toolchains//:all
build:system-clang --action_env=BAZEL_COMPILER=clang
build:system-clang --cxxopt=-std=c++23 --host_cxxopt=-std=c++23
build:system-clang --linkopt -fuse-ld=lld
build:system-clang-20 --config=system-clang
build:system-clang-20 --action_env=CC=clang-20 --host_action_env=CC=clang-20
build:system-clang-20 --action_env=CXX=clang++-20 --host_action_env=CXX=clang++-20
```

This uses Bazel's built-in CC auto-detection (`local_config_cc_toolchains`)
with environment variables pointing to specific clang binaries. This is a
simpler but less controllable approach.

## Nix LLVM Packages: No symlinkJoin Needed

Nix splits LLVM across multiple store paths, but that turns out not to
matter. The Nix `clang` package is a **wrapper script** (not an ELF binary)
that already knows where to find all its dependencies:

| Package | Path | What it provides |
|---------|------|-----------------|
| `llvmPackages_20.clang` | `/nix/store/...-clang-wrapper-20.1.8` | `clang`, `clang++`, `cc`, `c++` — bash wrapper scripts that invoke the real clang with correct `-isystem`, `-L`, `-B`, `--gcc-toolchain` flags |
| `llvmPackages_20.lld` | `/nix/store/...-lld-20.1.8` | `ld.lld` — the LLVM linker |
| `llvmPackages_20.llvm` | `/nix/store/...-llvm-20.1.8` | `llvm-ar`, `llvm-nm`, `llvm-objcopy`, `llvm-profdata`, etc. |

The clang wrapper is a bash script with a Nix store shebang
(`#!/nix/store/...-bash-5.3p9/bin/bash`). It automatically injects:

- **glibc headers**: `-idirafter /nix/store/...-glibc-2.42-51-dev/include`
- **Dynamic linker**: `/nix/store/...-glibc-2.42-51/lib/ld-linux-x86-64.so.2`
- **GCC support libs**: `-B/nix/store/...-gcc-15.2.0/lib/gcc/x86_64-unknown-linux-gnu/15.2.0`
- **Clang resource dir**: `-resource-dir=/nix/store/...-clang-wrapper-20.1.8/resource-root`

There is also `llvmPackages_20.libcxxStdenv.cc` which adds libc++ flags:
- `-cxx-isystem /nix/store/...-libcxx-20.1.8-dev/include/c++/v1`
- `-stdlib=libc++`

All of these are bash scripts — **no FHS dependency, no `/lib64` needed**.

### Verified: all tools available on PATH

```
$ nix-shell -p llvmPackages_20.clang llvmPackages_20.lld llvmPackages_20.llvm
$ which clang && which ld.lld && which llvm-ar && clang --version | head -1
/nix/store/...-clang-wrapper-20.1.8/bin/clang
/nix/store/...-lld-20.1.8/bin/ld.lld
/nix/store/...-llvm-20.1.8/bin/llvm-ar
clang version 20.1.8
```

## Recommended Approach: Use system-clang Config

Redpanda's `.bazelrc` already has a `system-clang` configuration that
bypasses `toolchains_llvm` entirely and uses Bazel's built-in CC
auto-detection.

### Build command

```bash
nix develop --command bazelisk build --config=system-clang //src/v/redpanda:redpanda
```

No `toolchains_llvm` download needed. No patches to `toolchains_llvm`.
Bazel auto-detects the Nix-wrapped clang from PATH.

## Alternative: toolchain_root for Full toolchains_llvm Integration

If the fine-grained flag control from `toolchains_llvm` is needed (e.g.
architecture-specific `-march` flags, custom sysroots), the
`llvm.toolchain_root()` mechanism can point to a Nix-provided LLVM
directory. This would require a `symlinkJoin` derivation to combine the
split Nix packages into a single tree, and careful sysroot handling.

This is more work and less necessary given that `system-clang` already
exists and the Nix wrapper handles include/library path resolution
automatically.

## Comparison with rules_python

| Aspect | rules_python | toolchains_llvm |
|--------|-------------|-----------------|
| System toolchain support in MODULE.bazel | **Not available** (was WORKSPACE-only) | **Already available** (`toolchain_root`) |
| Patch needed | Yes — new `local_toolchain` tag class | **No** — mechanism exists |
| Nix complication | Single binary (`python3`) | Split across multiple store paths |
| Solution | PATH lookup resolves to Nix store | Nix clang wrapper handles everything |
| Sysroot handling | Not applicable | Nix clang wrapper handles it |

---

## Implementation Log

### Issue 1: `@local_config_cc_toolchains` not visible in Bzlmod

The `system-clang` config references `@local_config_cc_toolchains//:all`,
but this repo was not visible from the main module under Bzlmod. It is
created by `rules_cc`'s `cc_configure_extension` module extension, but
only `rules_cc` itself called `use_repo` on it.

**Error:**
```
No repository visible as '@local_config_cc_toolchains' from main repository
```

**Fix:** Added to `MODULE.bazel` after the `rules_cc` dep:

```starlark
cc_configure = use_extension("@rules_cc//cc:extensions.bzl", "cc_configure_extension")
use_repo(cc_configure, "local_config_cc_toolchains")
```

**File:** `rules_cc/cc/extensions.bzl` — the extension creates both
`local_config_cc` and `local_config_cc_toolchains` repos via
`cc_autoconf_toolchains()` and `cc_autoconf()`.

### Issue 2: `py3_runtime.interpreter` is `None` for local Python

The `expand_with_stamp_vars` rule accessed
`toolchain.py3_runtime.interpreter` directly in its `tools` list. For
local/system Python toolchains (like our rules_python patch), the
`interpreter` attribute is `None` — they use `interpreter_path` (a string)
instead.

**Error:**
```
expected value of type 'File' for a member of parameter 'tools' but got NoneType
```

**Fix in `src/v/version/expand_with_stamp_vars.bzl`:**
```python
interpreter = toolchain.py3_runtime.interpreter
tools = [ctx.executable._tool] + ([interpreter] if interpreter else [])
```

Also changed `executable = ctx.executable._tool.path` to
`executable = ctx.executable._tool` (File object instead of path string)
for proper sandbox handling.

### Issue 3: NixOS has no `/bin/bash`

Bazel genrules use `/bin/bash` as the shell. NixOS does not have
`/bin/bash` — only `/usr/bin/env` and `/bin/sh` exist as FHS
compatibility paths. The Bazel sandbox (`processwrapper-sandbox`) also
doesn't mount `/bin/bash`.

**Error:**
```
src/main/tools/process-wrapper-legacy.cc:80: "execvp(/bin/bash, ...)": No such file or directory
```

**Fix:** The `nix/shell.nix` shellHook generates `.bazelrc.nix` with:
```
build --shell_executable=/nix/store/...-bash-5.3p9/bin/bash
```

This tells Bazel to use the Nix-provided bash for genrules instead of
`/bin/bash`.

### Issue 4: `#!/bin/bash` in rules_python bootstrap script

The rules_python `stage1_bootstrap_template.sh` uses `#!/bin/bash` as
its shebang. Even with `--shell_executable`, this doesn't help because
the shebang is baked into the generated wrapper script, not controlled by
Bazel's shell setting.

**Error:**
```
env: 'bash': No such file or directory
```

**Fix:** Changed `#!/bin/bash` to `#!/usr/bin/env bash` in
`rules_python/python/private/stage1_bootstrap_template.sh`.

### Issue 5: Sandbox PATH doesn't include Nix store paths

Even with `--shell_executable` pointing at Nix bash, scripts inside
actions couldn't find tools because Bazel's sandbox PATH doesn't include
Nix store paths. The rules_python bootstrap script uses `env bash` (via
`#!/usr/bin/env bash`) which requires `bash` on PATH.

**Error:**
```
env: 'bash': No such file or directory
```

**Fix:** Propagate the Nix PATH into actions via `.bazelrc.nix`:
```
build --action_env=PATH=<nix-store-paths...>
build --host_action_env=PATH=<nix-store-paths...>
```

**Trade-off:** This breaks build hermeticity — actions can see all tools
on the host PATH. Acceptable for dev shell, not for CI.

### Issue 6: `use_default_shell_env = False` blocks py_binary execution

The `expand_with_stamp_vars` rule had `use_default_shell_env = False`,
giving an empty environment to actions. The rules_python bootstrap
needs a functional PATH.

**Fix:** Changed to `use_default_shell_env = True` in
`src/v/version/expand_with_stamp_vars.bzl`.

### Issue 7: `ld.lld: error: unable to find library -lc++`

The `.bazelrc` has `--linkopt -stdlib=libc++` globally, which tells clang
to link against libc++. The Nix clang wrapper (default variant) injects
library paths via `NIX_LDFLAGS` which are consumed by the Nix `ld`
wrapper. But `-fuse-ld=lld` (from `system-clang` config) calls lld
directly, bypassing the Nix ld wrapper. So `-L/nix/store/.../libcxx/lib`
never reaches lld.

**Error (from `rules_foreign_cc` CMake build of c-ares):**
```
ld.lld: error: unable to find library -lc++
```

**Fix:** Pass all `NIX_*` environment variables through to actions, so
the Nix clang wrapper can inject the correct flags:
```
build --action_env=NIX_LDFLAGS
build --action_env=NIX_CC
build --action_env=NIX_BINTOOLS
...
```

Also set `LIBRARY_PATH` explicitly as a fallback:
```
build --action_env=LIBRARY_PATH=/nix/store/.../libcxx-20.1.8/lib
```

**Result:** libc++ linking works — the c-ares and base64 CMake builds
pass.

### Issue 8: `krb5` configure: `cannot compute sizeof (time_t)`

The krb5 `rules_foreign_cc` build runs autoconf's `AC_CHECK_SIZEOF`
which compiles AND executes a test program. The test program links
against OpenSSL (`-lcrypto`) which was built by another `rules_foreign_cc`
target. At runtime, the test binary can't find `libcrypto.so.3` because
`LD_LIBRARY_PATH` doesn't include the Bazel sandbox path where OpenSSL's
`.so` was placed.

**Error (from krb5 config.log):**
```
./conftest: error while loading shared libraries: libcrypto.so.3: cannot open shared object file
```

**Root cause:** `rules_foreign_cc` stages dependencies in
`krb5.ext_build_deps/openssl_foreign_cc/lib/`. The configure script
passes `-L<that-path>` to the compiler, so linking works. But the test
binary's RPATH doesn't include that path, so the dynamic linker can't
find `libcrypto.so.3` at runtime.

**Fix in `bazel/thirdparty/krb5.BUILD`:** Added `LD_LIBRARY_PATH` to the
`env` dict using `$$EXT_BUILD_DEPS` (a `rules_foreign_cc` variable that
expands to the dependency staging directory):

```python
env = {
    ...
    "LD_LIBRARY_PATH": "$$EXT_BUILD_DEPS/openssl_foreign_cc/lib",
},
```

**Result:** krb5 configure passes, krb5 builds successfully (41s).

### Issue 9: `libxml2` autogen: missing `pkg.m4`

After krb5 was fixed, the `libxml2` `rules_foreign_cc` build failed
during `autoreconf` because it couldn't find `pkg.m4` from `pkg-config`.

**Error:**
```
Couldn't find pkg.m4 from pkg-config. Install the appropriate package for
your distribution or set ACLOCAL_PATH to the directory containing pkg.m4.
```

**Root cause:** Nix sets `ACLOCAL_PATH` in the shell environment (pointing
to `automake`, `libtool`, `bison`, and `pkg-config` aclocal directories),
but this wasn't propagated into Bazel actions.

**Fix:** Added to `.bazelrc.nix` generation in `nix/shell.nix`:
```
build --action_env=ACLOCAL_PATH=<nix-aclocal-paths>
```

**Result:** libxml2 autoreconf and build pass.

### Issue 10: `protoc_minimal: error while loading shared libraries: libstdc++.so.6`

The `protoc_minimal` binary (built for the exec configuration) links
against `libstdc++.so.6` from GCC. The exec-config CC toolchain uses
libstdc++ (not libc++) because the global `-stdlib=libc++` flag only
applies to the target configuration. At runtime, the dynamic linker
can't find `libstdc++.so.6` because it's in the Nix store, not a
standard system path.

**Error:**
```
protoc_minimal: error while loading shared libraries: libstdc++.so.6:
cannot open shared object file: No such file or directory
```

**Fix:** Added GCC's lib directory to `LD_LIBRARY_PATH` alongside libc++:
```nix
gccLib = stdenv.cc.cc.lib;
# in .bazelrc.nix:
build --action_env=LD_LIBRARY_PATH=<libcxx-path>:<gcc-lib-path>
```

**Result:** protoc_minimal and all proto generation steps work.

### Issue 11: Seastar `future.hh` compilation error — wrong stdlib headers

After all toolchain/environment issues were resolved, the build
progressed to **2,751 sandbox processes** (3,297 total actions) before
hitting a C++ compilation error in Seastar's `future.hh`:

```
error: cannot initialize object parameter of type
'const seastar::future_state_base' with an expression of type
'future_state' (aka 'future_state<std::variant<...>>')
```

**Root cause:** The compilation was using **libstdc++ headers** (from
GCC) instead of **libc++ headers**. Two things were wrong:

1. **Nix clang wrapper**: `llvmPackages_20.clang` (the default) uses
   libstdc++ as its standard library. Its `-cxx-isystem` points at
   `gcc-15.2.0/include/c++/15.2.0` (libstdc++). Redpanda's code
   expects libc++ — the `toolchains_llvm` config uses `builtin-libc++`
   which passes `-stdlib=libc++` at compile time.

2. **`system-clang` config**: Missing `-stdlib=libc++` as a compile
   flag. The `.bazelrc` only had `-stdlib=libc++` as a **link flag**
   (line 7: `--linkopt -stdlib=libc++`). The `toolchains_llvm` CC
   toolchain injects `-stdlib=libc++` as a **compile flag**
   (`cc_toolchain_config.bzl` line 265), but the `system-clang` config
   relied on auto-detection, which doesn't add it.

**Evidence (comparing `clang++ -v` output):**

| Wrapper | C++ include path | Defines `__GLIBCXX__`? |
|---------|-----------------|----------------------|
| `llvmPackages_20.clang` | `gcc-15.2.0/include/c++/15.2.0` (libstdc++) | Yes |
| `llvmPackages_20.libcxxClang` | `libcxx-20.1.8-dev/include/c++/v1` (libc++) | No |

Seastar's `future.hh` has `#ifdef __GLIBCXX__` conditional code paths
(lines 447, 454) that take different optimization shortcuts for
libstdc++ vs libc++. Compiling with the wrong stdlib headers causes
template instantiation failures because the Seastar code and the
standard library implementation make incompatible assumptions.

**Seastar `future.hh` details (important for future reference):**

Seastar's `future.hh` contains `#ifdef __GLIBCXX__` conditional code
in `future_state_base::any`:

- **`take_exception()` (line 447):** With libstdc++, skips explicit
  `~exception_ptr()` destructor call on moved-from values (known no-op
  in libstdc++). With libc++, calls it explicitly.

- **`move_it()` (line 454):** With libstdc++, uses `memmove` +
  invalidate (relies on libstdc++'s `exception_ptr` being a plain
  pointer). With libc++, uses proper typed move via `take_exception()`.

These optimizations rely on internal knowledge of the stdlib
implementation. Compiling with the wrong stdlib's headers produces
code that makes invalid assumptions about type layouts and causes
template instantiation failures.

**Fix:**

`nix/shell.nix`: Switched from `llvmPackages_20.clang` to
`llvmPackages_20.libcxxClang` — the Nix clang wrapper variant that
uses libc++ headers and injects `-cxx-isystem` pointing to
`libcxx-20.1.8-dev/include/c++/v1`.

**Why not also add `--cxxopt=-stdlib=libc++`?** Initially tried adding
`build:system-clang --cxxopt=-stdlib=libc++ --host_cxxopt=-stdlib=libc++`
to `.bazelrc`, but the Nix `libcxxClang` wrapper already injects libc++
include paths via `-cxx-isystem`. When Bazel also passes `-stdlib=libc++`
explicitly, clang considers it "unused during compilation" (the includes
are already handled by the wrapper). Combined with Redpanda's `-Werror`
(from `bazel/internal.bzl`), this becomes a fatal error:
```
clang: error: argument unused during compilation: '-stdlib=libc++' [-Werror,-Wunused-command-line-argument]
```
The `libcxxClang` wrapper alone is sufficient — it handles compile-time
headers, and the existing global `--linkopt -stdlib=libc++` handles
link-time.

### Issue 12: Exec-config tools can't find `libc++.so.1` at runtime

After fixing the Seastar compilation, exec-config binaries like
`protoc-gen-upb_stage0` and `protoc` linked against libc++ dynamically
(via `--host_linkopt -stdlib=libc++`) but couldn't find `libc++.so.1`
at runtime in the Bazel sandbox.

**Error:**
```
protoc: error while loading shared libraries: libc++.so.1: cannot open shared object file
```

**Root cause:** The global `--linkopt -stdlib=libc++` only applies to
target-config linking. Exec-config tools need `--host_linkopt`. Initially
tried `--host_linkopt -stdlib=libc++` which dynamically links libc++.
But the Bazel sandbox doesn't propagate `LD_LIBRARY_PATH` to all action
types (the `ProtocAuthenticityCheck` action couldn't find `libc++.so.1`
or even `grep`).

The `toolchains_llvm` CC toolchain avoids this by **statically** linking
libc++ (`-l:libc++.a -l:libc++abi.a`) for all configurations.

**First attempt:** Static libc++ linking (`--host_linkopt -l:libc++.a`)
caused **duplicate symbol errors** in ragel build — both `libstdc++.a`
(from Nix wrapper's `NIX_LDFLAGS`) and `libc++.a` (from our flag) were
being linked. `std::bad_exception`, `std::bad_alloc` etc. defined in
both archives.

**Fix:** Dynamic libc++ linking + suppress ProtocAuthenticityCheck:
```bazelrc
# .bazelrc system-clang config:
build:system-clang --host_linkopt -stdlib=libc++
build:system-clang --host_linkopt --unwindlib=libgcc
build:system-clang --linkopt -fuse-ld=lld --host_linkopt -fuse-ld=lld
```

The `ProtocAuthenticityCheck` rule uses `ctx.actions.run_shell()`
**without** `use_default_shell_env = True`, so it gets a minimal
environment where `grep`, `LD_LIBRARY_PATH`, and `PATH` aren't
available. Suppressed via `.bazelrc.nix`:
```bazelrc
build --@protobuf//bazel/toolchains:allow_nonstandard_protoc
```

### Issue 13: Missing `xfs/linux.h` — Seastar needs xfsprogs

Seastar's `src/core/file.cc` includes `<xfs/linux.h>` for XFS ioctl
support. This header comes from `xfsprogs` development package.

**Fix:** Added `xfsprogs` to `nix/shell.nix` packages.

### Issue 14: `protoc` Exit 127 — `libc++.so.1` not found at runtime

The `RedpandaProtoGen` rule in `bazel/pbgen/pbgen.bzl` uses
`ctx.actions.run()` without `use_default_shell_env = True`. The
protoc binary (dynamically linked against libc++ via
`--host_linkopt -stdlib=libc++`) can't find `libc++.so.1` because
`LD_LIBRARY_PATH` is not in the action environment.

**Fix:** Added `use_default_shell_env = True` to the protoc action
in `bazel/pbgen/pbgen.bzl`.

### Issue 15: `xfsprogs` undefined variable in shell.nix

The `xfsprogs` package was added to the `packages` list but not to the
function parameters at the top of `nix/shell.nix`. This caused the
nix-shell to fail to evaluate, meaning the `.bazelrc.nix` was not
regenerated and the previous build used a stale environment.

Additionally, `xfsprogs` has split outputs in nixpkgs (`bin`, `dev`,
`out`, `doc`, `man`). The default output is `bin` (no headers). The
`dev` output at `/nix/store/...-xfsprogs-6.17.0-dev/include/xfs/linux.h`
contains the needed headers. When listed in `mkShell.packages`
(→ `nativeBuildInputs`), Nix's stdenv setup hooks automatically propagate
the `dev` output's include directory into `NIX_CFLAGS_COMPILE`, which
the Nix clang wrapper reads to inject `-isystem` flags.

**Fix:** Added `xfsprogs` to the function parameters in `nix/shell.nix`.

### Issue 16: `valgrind/valgrind.h` not found

Seastar unconditionally includes `<valgrind/valgrind.h>` in
`src/core/thread.cc` and `src/core/linux-aio.cc`. These includes are
NOT guarded by any `#ifdef SEASTAR_HAVE_VALGRIND` conditional. The
standard Redpanda build environment provides valgrind headers via the
sysroot (`bazel/toolchain/Dockerfile.sysroot` installs `valgrind`).
The CMake build uses `find_package(Valgrind REQUIRED)`.

In the Seastar Bazel BUILD file, there is no explicit valgrind
dependency — it relies on the system/sysroot headers being available.

**Fix:** Added `valgrind` to both function parameters and packages
list in `nix/shell.nix`. Like xfsprogs, `valgrind.dev` provides the
header at `include/valgrind/valgrind.h`, and Nix's setup hooks
propagate it into `NIX_CFLAGS_COMPILE`.

### Issue 17: protoc `libc++.so.1` — RPATH fix

Despite `use_default_shell_env = True` in `pbgen.bzl` and
`--action_env=LD_LIBRARY_PATH` in `.bazelrc.nix`, the protoc binary
(exec-config, dynamically linked against libc++) still failed to find
`libc++.so.1` at runtime. The `use_default_shell_env = True` should
propagate `LD_LIBRARY_PATH` to actions, but in practice the protoc
actions still got Exit 127.

**Root cause:** Bazel's `processwrapper-sandbox` may not propagate all
environment variables to spawned processes in all cases, or there may
be a Bazel 8.x behavior change with `use_default_shell_env`.

**Fix:** Added RPATH linker flags to `.bazelrc.nix` generation:
```
build --linkopt=-Wl,-rpath,<libcxx-lib-path>
build --linkopt=-Wl,-rpath,<gcc-lib-path>
build --host_linkopt=-Wl,-rpath,<libcxx-lib-path>
build --host_linkopt=-Wl,-rpath,<gcc-lib-path>
```

This embeds the Nix store library paths directly in the binary's ELF
RPATH, so the dynamic linker can find `libc++.so.1` and `libstdc++.so.6`
without relying on `LD_LIBRARY_PATH` being propagated through the
Bazel sandbox. This is the same approach the standard `toolchains_llvm`
toolchain uses — its static libc++ linking avoids the runtime
dependency entirely, but RPATH achieves the same reliability for
dynamic linking.

The `use_default_shell_env = True` in `pbgen.bzl` is kept as a
belt-and-suspenders measure for other env vars the protoc plugin
might need.

---

## Summary of all changes made

| File | Change | Purpose |
|------|--------|---------|
| `nix/shell.nix` | LLVM packages (using `libcxxClang`), `xfsprogs`, `valgrind`, `stdenv`; shellHook generates `.bazelrc.nix` with env vars, RPATH flags, + `--@protobuf//...allow_nonstandard_protoc` | Nix dev environment for Bazel builds |
| `MODULE.bazel` | Added `cc_configure_extension` + `use_repo(cc_configure, "local_config_cc_toolchains")` | Make `@local_config_cc_toolchains` visible for `system-clang` config |
| `.bazelrc` | Added `try-import %workspace%/.bazelrc.nix`; `system-clang` config: `--host_linkopt -fuse-ld=lld`, `--host_linkopt -stdlib=libc++`, `--host_linkopt --unwindlib=libgcc` | Load Nix-specific settings; exec-config libc++ linking |
| `.gitignore` | Added `.bazelrc.nix` | Don't track generated file |
| `src/v/version/expand_with_stamp_vars.bzl` | Handle `None` interpreter, `use_default_shell_env = True`, use File object for executable | Fix for local Python toolchain + NixOS |
| `rules_python/.../stage1_bootstrap_template.sh` | `#!/bin/bash` -> `#!/usr/bin/env bash` | NixOS compat (no `/bin/bash`) |
| `bazel/thirdparty/krb5.BUILD` | Added `LD_LIBRARY_PATH=$$EXT_BUILD_DEPS/openssl_foreign_cc/lib` to env | Fix configure runtime tests finding libcrypto.so |
| `bazel/pbgen/pbgen.bzl` | Added `use_default_shell_env = True` to `RedpandaProtoGen` action | Fix protoc runtime env propagation |

## Build results

**Progression:**
1. Attempt 1: `@local_config_cc_toolchains` not found → fixed
2. Attempt 2: `py3_runtime.interpreter` is None → fixed
3. Attempt 3: `execvp(/bin/bash)` fails → fixed with `--shell_executable`
4. Attempt 5: `env: 'bash': No such file or directory` → fixed with `--action_env=PATH`
5. Attempt 6: `ld.lld: unable to find library -lc++` → fixed with `NIX_*` env vars
6. Attempt 8: `krb5` configure fails (libcrypto.so.3 not found) → fixed with `LD_LIBRARY_PATH` in krb5.BUILD
7. Attempt 9: `libxml2` autogen fails (pkg.m4 not found) → fixed with `ACLOCAL_PATH`
8. Attempt 10: `protoc_minimal` can't find libstdc++.so.6 → fixed with GCC lib in `LD_LIBRARY_PATH`
9. Attempt 11: Seastar `future.hh` template error → fixed with `libcxxClang`
10. Attempt 11b: `-stdlib=libc++` cxxopt "unused during compilation" with `-Werror` → removed cxxopt, Nix wrapper handles it
11. Attempt 12a: exec-config `protoc-gen-upb_stage0` link fails (undefined libc++ symbols) → added `--host_linkopt -stdlib=libc++`
12. Attempt 12b: `ProtocAuthenticityCheck` fails (no grep/libc++.so in minimal env) → suppressed with `--@protobuf//...allow_nonstandard_protoc`
13. Attempt 12c: static `libc++.a` caused duplicate symbols with `libstdc++.a` (ragel) → reverted to dynamic `-stdlib=libc++`
14. Attempt 14: Build reached 8,500+ actions — Seastar `xfs/linux.h` not found → added `xfsprogs` to shell.nix
15. Attempt 14: `protoc` Exit 127 (libc++.so.1 missing) → added `use_default_shell_env = True` to `pbgen.bzl`
16. Attempt 15: Build reached 8,579/8,581 — 3 remaining issues:
    - `xfsprogs` undefined in shell.nix (missing from function params) → fixed
    - `valgrind/valgrind.h` not found (missing from shell.nix) → added valgrind
    - protoc libc++.so.1 still failing despite `use_default_shell_env` → added RPATH flags
17. **Attempt 16 (2026-03-05): Next build with all three fixes**

## Open Questions

1. **`--action_env=PATH` hermeticity**: Propagating the full host PATH
   into build actions breaks build hermeticity. Acceptable for dev shell
   but not for CI. A minimal PATH could be constructed instead.

2. **`#!/bin/bash` in rules_python**: Should be upstreamed — NixOS and
   Guix don't have `/bin/bash`.

3. **Cross-compilation**: The Nix approach provides native-architecture
   LLVM only. Cross-compilation would need additional work.

4. **Version match**: nixpkgs has LLVM 20.1.8, matching Redpanda's
   "current" compiler exactly.

5. **RPATH with Nix store paths**: The RPATH flags embed absolute Nix
   store paths in binaries. This is standard for NixOS but means built
   binaries are not portable to non-NixOS systems. Acceptable for dev
   builds; CI/release builds should use the hermetic `toolchains_llvm`
   config.

## Key Technical Details

### Nix LLVM clang wrapper variants

nixpkgs provides multiple clang wrapper variants per LLVM version:

| Package | C++ stdlib | Include path |
|---------|-----------|--------------|
| `llvmPackages_20.clang` | libstdc++ (GCC) | `gcc-15.2.0/include/c++/15.2.0` |
| `llvmPackages_20.libcxxClang` | libc++ | `libcxx-20.1.8-dev/include/c++/v1` |
| `llvmPackages_20.clangUseLLVM` | libc++ + compiler-rt + libunwind | (full LLVM runtime) |

Both wrappers use the same underlying `clang-20.1.8` binary. The
difference is in the `nix-support/add-flags.sh` which sets
`NIX_CXXSTDLIB_COMPILE` to inject the appropriate headers via
`-cxx-isystem`.

**Important:** Both Nix wrappers inject
`-D _LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE` (a
nixpkgs default), but with the regular `clang` wrapper this define is
meaningless because libstdc++ ignores it.

### Why `-stdlib=libc++` as cxxopt doesn't work with Nix wrappers

The Nix clang wrapper injects libc++ include paths via `-cxx-isystem`
and `-isystem` flags. When Bazel also passes `-stdlib=libc++` as an
explicit compiler flag, clang considers it "unused during compilation"
because the include search paths are already set. With Redpanda's
`-Werror` (from `bazel/internal.bzl` `redpanda_copts()`), this
warning becomes a fatal error. The `toolchains_llvm` CC toolchain
doesn't have this problem because it uses a non-Nix clang binary
where `-stdlib=libc++` is the primary mechanism for finding headers.

### toolchains_llvm vs system-clang flag comparison

| Flag | `toolchains_llvm` | `system-clang` |
|------|------------------|----------------|
| `-stdlib=libc++` (compile) | Yes (from `builtin-libc++` default) | No (Nix wrapper handles it) |
| `-stdlib=libc++` (link) | Yes (static: `-l:libc++.a -l:libc++abi.a`) | Yes (`--linkopt -stdlib=libc++`) |
| `-std=c++23` | Yes (`cxx_standard`) | Yes (`--cxxopt`) |
| `--target=x86_64-unknown-linux-gnu` | Yes | No (compiler default) |
| `-fuse-ld=lld` | Yes | Yes (`--linkopt`) |
| `-Xclang -fno-cxx-modules` | Yes (LLVM 14+) | No |
| `-no-canonical-prefixes` | Yes | No |
| `-Wno-builtin-macro-redefined` | Yes | No |
| `__DATE__/__TIME__` redaction | Yes | No |

## Next Steps

1. Rebuild with `xfsprogs` in shell.nix + `pbgen.bzl` fix
2. If build succeeds: clean up, test a clean build from scratch
3. Consider upstreaming fixes:
   - `#!/usr/bin/env bash` to rules_python
   - `use_default_shell_env = True` to protobuf's ProtocAuthenticityCheck
4. Long-term: consider providing protoc from nixpkgs instead of
   building from source (avoids libc++ runtime dependency issues)

---

## Successful Build (2026-03-05)

**Attempt 16 succeeded.** Full build of `//src/v/redpanda:redpanda`
completed with zero errors:

```
Target //src/v/redpanda:redpanda up-to-date:
  bazel-bin/src/v/redpanda/redpanda
INFO: Elapsed time: 1770.846s, Critical Path: 552.29s
INFO: 3574 processes: 5012 action cache hit, 104 internal, 3470 processwrapper-sandbox.
INFO: Build completed successfully, 3574 total actions
```

8,581 total actions analyzed, 3,470 executed in sandbox (rest from
cache), all passed.

### What fixed it (Attempt 15 → 16)

Three issues blocked the previous attempt (which reached 8,579/8,581):

#### 1. `xfsprogs` undefined variable in `shell.nix`

`xfsprogs` was added to the `packages` list but not to the function
parameters at the top of the file. The nix-shell could not evaluate,
so `.bazelrc.nix` was never regenerated — the build ran with a stale
environment from a previous session.

**Lesson:** When using `callPackage`-style Nix files, every package
referenced in the body must appear in the function argument list.
There is no implicit scope — missing args cause an evaluation error,
not a runtime error.

#### 2. `valgrind/valgrind.h` not found

Seastar unconditionally includes `<valgrind/valgrind.h>` in
`src/core/thread.cc` and `src/core/linux-aio.cc` (no `#ifdef` guard).
The standard Redpanda build gets valgrind from its sysroot
(`bazel/toolchain/Dockerfile.sysroot`). The CMake build uses
`find_package(Valgrind REQUIRED)`. The Bazel BUILD has no explicit
valgrind dependency — it relies on system headers.

**Fix:** Added `valgrind` to `shell.nix`. Nix's stdenv setup hooks
propagate the `dev` output's include path into `NIX_CFLAGS_COMPILE`,
which the Nix clang wrapper injects as `-isystem` flags.

#### 3. protoc `libc++.so.1` not found at runtime

Despite `use_default_shell_env = True` in `pbgen.bzl` and
`--action_env=LD_LIBRARY_PATH` in `.bazelrc.nix`, exec-config
binaries (protoc) still couldn't find `libc++.so.1`. The environment
variable propagation through Bazel's `processwrapper-sandbox` was
unreliable for `ctx.actions.run()` actions.

**Fix:** Added RPATH linker flags to `.bazelrc.nix`:
```
build --linkopt=-Wl,-rpath,<libcxx-lib-path>
build --linkopt=-Wl,-rpath,<gcc-lib-path>
build --host_linkopt=-Wl,-rpath,<libcxx-lib-path>
build --host_linkopt=-Wl,-rpath,<gcc-lib-path>
```

This embeds the Nix store library paths directly in the ELF RPATH of
every linked binary. The dynamic linker finds `libc++.so.1` and
`libstdc++.so.6` without any environment variables — making it robust
regardless of how Bazel spawns the process.

### Learnings

#### Nix multi-output packages require care

Many nixpkgs packages split their outputs (e.g., `xfsprogs` has
`bin`, `dev`, `out`, `doc`, `man`). The default output is often `bin`
(no headers). When listed in `mkShell.packages` (→
`nativeBuildInputs`), Nix's stdenv setup hooks automatically select
the `dev` output and propagate its include paths into
`NIX_CFLAGS_COMPILE`. This works transparently — but only if the
package is actually in scope (in the function arguments).

#### RPATH > LD_LIBRARY_PATH for Bazel sandbox

Relying on `LD_LIBRARY_PATH` propagation through Bazel actions is
fragile. Different action types (`ctx.actions.run()` vs
`ctx.actions.run_shell()`), different configurations (target vs exec),
and sandbox implementations can all interfere. RPATH is baked into the
binary at link time and works unconditionally. For a Nix dev shell
where all library paths are stable Nix store paths, RPATH is the
correct approach.

The `toolchains_llvm` hermetic toolchain avoids this entirely by
statically linking libc++ (`-l:libc++.a -l:libc++abi.a`). RPATH
is the dynamic-linking equivalent of that approach.

#### `use_default_shell_env = True` is not sufficient alone

In Bazel 8.x with `processwrapper-sandbox`, `use_default_shell_env`
on `ctx.actions.run()` should propagate `--action_env` variables, but
in practice the protoc actions still failed with Exit 127. The RPATH
fix made this moot. The `use_default_shell_env = True` in `pbgen.bzl`
is retained as a belt-and-suspenders measure for other env vars the
protoc plugin might need.

#### Seastar's hidden system dependencies

Seastar's Bazel BUILD has no explicit dependencies on `xfsprogs` or
`valgrind` — these are expected to come from the system/sysroot. The
`Dockerfile.sysroot` installs them, and the CMake build uses
`find_package()`. When building outside the Docker sysroot (e.g., with
Nix), these implicit dependencies must be discovered by reading
Seastar's source for `#include` directives that reference system
headers.

**System headers required by Seastar (for future reference):**

| Header | Package | Source files |
|--------|---------|-------------|
| `xfs/linux.h` | xfsprogs (dev) | `src/core/file.cc`, `src/core/reactor.cc` |
| `valgrind/valgrind.h` | valgrind (dev) | `src/core/thread.cc`, `src/core/linux-aio.cc` |

### Improvements for future work

1. **Clean build test**: Run `bazel clean --expunge` then rebuild to
   verify the full build works without any cached artifacts.

2. **Upstream contributions**:
   - `#!/usr/bin/env bash` in `rules_python`
     `stage1_bootstrap_template.sh` — NixOS and Guix don't have
     `/bin/bash`.
   - `use_default_shell_env = True` in protobuf's
     `ProtocAuthenticityCheck` rule — or better yet, the protobuf
     project should not require `grep` in a minimal action env.

3. **Reduce hermeticity leakage**: The current `--action_env=PATH`
   propagates the entire host PATH. A minimal PATH containing only
   the necessary Nix store paths would be more hermetic. Could be
   constructed in `shellHook` by filtering `$PATH` to only include
   Nix store entries.

4. **aarch64-linux testing**: The flake supports both `x86_64-linux`
   and `aarch64-linux`. The `NIX_CC_WRAPPER_TARGET_HOST_*` env vars
   in `.bazelrc.nix` are currently hardcoded to
   `x86_64_unknown_linux_gnu`. These should be made
   architecture-aware.

5. **Protoc from nixpkgs**: Providing protoc as a pre-built Nix
   package (instead of building from source in Bazel) would eliminate
   the RPATH/libc++ complexity for exec-config tools entirely.

6. **CI integration**: For CI use, consider a `nix build` derivation
   (in `nix/redpanda.nix`) that uses `buildBazelPackage` or similar,
   providing full Nix sandboxing rather than the dev-shell approach.

---

## End-to-End Verification (2026-03-05)

After the successful build, we verified the binary runs correctly and
serves Kafka protocol traffic.

### Binary verification

```
$ file bazel-bin/src/v/redpanda/redpanda
ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked,
interpreter /nix/store/...-glibc-2.42-51/lib/ld-linux-x86-64.so.2,
for GNU/Linux 3.10.0, not stripped

$ nix develop --command bazel-bin/src/v/redpanda/redpanda --version
v0.0.0-dev - 0000000000000000000000000000000000000000
```

The binary is 237MB, dynamically linked against the Nix glibc, and
reports `v0.0.0-dev` (expected for a dev build without stamp vars).
The `--help` flag lists all Redpanda and Seastar options.

### Single-node cluster startup

Started a single-node cluster using a minimal config:

```bash
nix develop --command bazel-bin/src/v/redpanda/redpanda \
  --redpanda-cfg /tmp/redpanda-test/redpanda.yaml \
  --smp 1 --memory 512M --reserve-memory 0
```

Config: `developer_mode: true`, Kafka on `127.0.0.1:9092`, admin on
`127.0.0.1:9644`, data in `/tmp/redpanda-test/data`.

Startup completed successfully with key log lines:

```
cluster - controller.cc - Cluster UUID created <uuid>
feature_manager.cc - Activating features after upgrade...
admin_api_server - Started HTTP admin service listening at 127.0.0.1:9644
main - Started Kafka API server listening at 127.0.0.1:9092
main - Successfully started Redpanda!
```

### Admin API health check

```
$ curl -s http://127.0.0.1:9644/v1/cluster/health_overview | python3 -m json.tool
{
    "is_healthy": true,
    "unhealthy_reasons": [],
    "controller_id": 0,
    "all_nodes": [0],
    "nodes_down": [],
    "leaderless_count": 0,
    "under_replicated_count": 0
}
```

```
$ curl -s http://127.0.0.1:9644/v1/brokers | python3 -m json.tool
[
    {
        "node_id": 0,
        "num_cores": 1,
        "membership_status": "active",
        "is_alive": true,
        "version": "v0.0.0-dev - ...",
        "disk_space": [{"path": "/tmp/redpanda-test/data", ...}]
    }
]
```

### Kafka protocol test (produce & consume)

Used `kafka-python-ng` (added to `nix/shell.nix` as a Python package
dependency for dev/test convenience):

```python
from kafka import KafkaProducer, KafkaConsumer
from kafka.admin import KafkaAdminClient, NewTopic

admin = KafkaAdminClient(bootstrap_servers='127.0.0.1:9092')
admin.create_topics([NewTopic('test-nix-build', num_partitions=1, replication_factor=1)])

producer = KafkaProducer(bootstrap_servers='127.0.0.1:9092')
for i in range(5):
    producer.send('test-nix-build', value=f'hello from nix build #{i}'.encode())
producer.flush()

consumer = KafkaConsumer('test-nix-build', bootstrap_servers='127.0.0.1:9092',
                         auto_offset_reset='earliest', consumer_timeout_ms=5000)
for msg in consumer:
    print(f'Consumed: {msg.value.decode()}')
```

**Output:**

```
Topic created: test-nix-build
Produced 5 messages
  Consumed: hello from nix build #0
  Consumed: hello from nix build #1
  Consumed: hello from nix build #2
  Consumed: hello from nix build #3
  Consumed: hello from nix build #4
Total consumed: 5 messages
```

### Test summary

| Test | Result |
|------|--------|
| Binary exists and is valid ELF | Pass |
| `--version` reports dev version | Pass |
| `--help` shows all options | Pass |
| Single-node cluster starts | Pass |
| Admin API `/v1/cluster/health_overview` | Pass (`is_healthy: true`) |
| Admin API `/v1/brokers` | Pass (1 broker, active, alive) |
| Kafka topic creation | Pass |
| Kafka produce (5 messages) | Pass |
| Kafka consume (5 messages) | Pass |

All tests passed. The Nix+Bazel-built Redpanda binary is fully
functional — it starts a cluster, serves the admin API, and handles
Kafka protocol produce/consume correctly.
