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

**Fix:** Changed to static libc++ linking for exec config:
```bazelrc
build:system-clang --host_linkopt -l:libc++.a --host_linkopt -l:libc++abi.a
build:system-clang --host_linkopt --unwindlib=libgcc
build:system-clang --linkopt -fuse-ld=lld --host_linkopt -fuse-ld=lld
```

---

## Summary of all changes made

| File | Change | Purpose |
|------|--------|---------|
| `nix/shell.nix` | LLVM packages (using `libcxxClang` for libc++ headers) + `stdenv`, shellHook generates `.bazelrc.nix` with `--shell_executable`, `--action_env=PATH`, `NIX_*` vars, `LIBRARY_PATH`, `LD_LIBRARY_PATH`, `ACLOCAL_PATH` | Nix dev environment for Bazel builds |
| `MODULE.bazel` | Added `cc_configure_extension` + `use_repo(cc_configure, "local_config_cc_toolchains")` | Make `@local_config_cc_toolchains` visible for `system-clang` config |
| `.bazelrc` | Added `try-import %workspace%/.bazelrc.nix`; `system-clang` config: added `--host_linkopt -fuse-ld=lld`, `--host_linkopt --unwindlib=libgcc`, `--host_linkopt -l:libc++.a -l:libc++abi.a` | Load Nix-specific settings; static libc++ for exec-config tools |
| `.gitignore` | Added `.bazelrc.nix` | Don't track generated file |
| `src/v/version/expand_with_stamp_vars.bzl` | Handle `None` interpreter, `use_default_shell_env = True`, use File object for executable | Fix for local Python toolchain + NixOS |
| `rules_python/.../stage1_bootstrap_template.sh` | `#!/bin/bash` -> `#!/usr/bin/env bash` | NixOS compat (no `/bin/bash`) |
| `bazel/thirdparty/krb5.BUILD` | Added `LD_LIBRARY_PATH=$$EXT_BUILD_DEPS/openssl_foreign_cc/lib` to env | Fix configure runtime tests finding libcrypto.so |

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
11. Attempt 12a: exec-config `protoc-gen-upb_stage0` link fails (undefined libc++ symbols) → added `--host_linkopt` flags
12. Attempt 12b: exec-config `protoc` can't find `libc++.so.1` at runtime → switched to static `libc++.a` linking
13. **Attempt 13 (2026-03-05, in progress): Build running with static libc++ for exec config**

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

1. Wait for current build to complete — already past 6,000+ actions
2. Achieve a full clean build of `//src/v/redpanda:redpanda`
3. Consider upstreaming the `#!/usr/bin/env bash` fix to rules_python
