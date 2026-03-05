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

Redpanda's `.bazelrc` (lines 27–37) already has a `system-clang`
configuration that bypasses `toolchains_llvm` entirely and uses Bazel's
built-in CC auto-detection:

```bazelrc
build:system-clang --extra_toolchains=@local_config_cc_toolchains//:all
build:system-clang --action_env=BAZEL_COMPILER=clang
build:system-clang --cxxopt=-std=c++23 --host_cxxopt=-std=c++23
build:system-clang --linkopt -fuse-ld=lld
```

This works with Nix-provided clang because:

1. `@local_config_cc_toolchains` auto-detects `CC` from the environment
2. The Nix clang wrapper handles all include paths, library paths, and
   sysroot resolution internally
3. `-fuse-ld=lld` tells clang to use `ld.lld` from PATH (provided by
   `llvmPackages_20.lld`)
4. The wrapper scripts are bash, not ELF — no FHS dependency

### Dev shell changes

Add the LLVM tools to `nix/shell.nix`:

```nix
{
  mkShell,
  bazelisk,
  llvmPackages_20,
  python312,
  ...
}:

mkShell {
  packages = [
    bazelisk
    llvmPackages_20.clang     # clang, clang++ wrapper scripts
    llvmPackages_20.lld       # ld.lld
    llvmPackages_20.llvm      # llvm-ar, llvm-objcopy, etc.
    llvmPackages_20.libcxx    # libc++ runtime library
    python312
    ...
  ];

  shellHook = ''
    export CC=clang
    export CXX=clang++
  '';
}
```

### Build command

```bash
nix develop --command bazelisk build --config=system-clang --action_env=PATH //src/v/redpanda:redpanda
```

No `toolchains_llvm` download needed. No patches to any rule set. Bazel
auto-detects the Nix-wrapped clang from PATH.

## Alternative: toolchain_root for Full toolchains_llvm Integration

If the fine-grained flag control from `toolchains_llvm` is needed (e.g.
architecture-specific `-march` flags, custom sysroots), the
`llvm.toolchain_root()` mechanism can point to a Nix-provided LLVM
directory. This would require a `symlinkJoin` derivation to combine the
split Nix packages into a single tree, and careful sysroot handling.

This is more work and less necessary given that `system-clang` already
exists and the Nix wrapper handles include/library path resolution
automatically

## Comparison with rules_python

| Aspect | rules_python | toolchains_llvm |
|--------|-------------|-----------------|
| System toolchain support in MODULE.bazel | **Not available** (was WORKSPACE-only) | **Already available** (`toolchain_root`) |
| Patch needed | Yes — new `local_toolchain` tag class | **No** — mechanism exists |
| Nix complication | Single binary (`python3`) | Split across multiple store paths |
| Solution | PATH lookup resolves to Nix store | `symlinkJoin` to create combined tree |
| Sysroot handling | Not applicable | Needs separate handling (Redpanda uses custom sysroots) |

## Key Finding

**No patch to toolchains_llvm is required.** The `llvm.toolchain_root()`
tag class already does what we need. The work is:

1. Create a Nix derivation (`symlinkJoin`) that combines LLVM packages into
   a single directory tree matching the expected layout
2. Wire that path into MODULE.bazel (via `toolchain_root` with the Nix store
   path)
3. Handle sysroots — Redpanda uses custom Ubuntu 22.04 sysroots downloaded
   from GitHub; for Nix builds these would need to be replaced with
   Nix-provided system headers and libraries

---

## Implementation Log

### What we did

#### 1. Added LLVM packages to `nix/shell.nix`

Added `llvmPackages_20.clang`, `.lld`, `.llvm`, `.libcxx` and set
`CC=clang CXX=clang++` in the shellHook. Verified all tools resolve:

```
$ nix develop --command bash -c 'which clang && clang --version | head -1'
/nix/store/3pmk0q90sb2qrbf4zj8cfhrzbf0jh022-clang-wrapper-20.1.8/bin/clang
clang version 20.1.8
```

#### 2. Registered `local_config_cc_toolchains` in MODULE.bazel

The `system-clang` config references `@local_config_cc_toolchains//:all`,
but this repo was not visible from the main module. It is created by
`rules_cc`'s `cc_configure_extension` but scoped to `rules_cc` only.

**Fix:** Added to `MODULE.bazel` after the `rules_cc` dep:

```starlark
cc_configure = use_extension("@rules_cc//cc:extensions.bzl", "cc_configure_extension")
use_repo(cc_configure, "local_config_cc_toolchains")
```

This made the toolchain repo visible and the `system-clang` config analyzable.

#### 3. Fixed `expand_with_stamp_vars.bzl` for local Python runtime

The `expand_with_stamp_vars` rule accessed `toolchain.py3_runtime.interpreter`
which is `None` for local/system Python toolchains (they use
`interpreter_path` instead — a string, not a File). The rule already had
a conditional handling `None` in its `tools` list.

#### 4. Fixed rules_python `#!/bin/bash` shebang for NixOS

The rules_python `stage1_bootstrap_template.sh` uses `#!/bin/bash` as its
shebang. NixOS does not have `/bin/bash` — only `/usr/bin/env` and `/bin/sh`
exist as FHS compatibility paths.

**Fix:** Changed `#!/bin/bash` to `#!/usr/bin/env bash` in
`rules_python/python/private/stage1_bootstrap_template.sh`.

#### 5. Fixed `use_default_shell_env` for py_binary in Bazel actions

The `expand_with_stamp_vars` rule had `use_default_shell_env = False`,
which gave an empty PATH to actions. The rules_python bootstrap script
needs `env` and `bash` on PATH to execute. Changed to
`use_default_shell_env = True`.

Even with `use_default_shell_env = True`, Bazel's default PATH does not
include Nix store paths. The solution is `--action_env=PATH` which
propagates the host PATH into build actions.

### Current status: nearly working

**Build result with `--config=system-clang --action_env=PATH`:**

- 8,579 of 8,581 actions completed successfully (C++ compilation works)
- **One failure:** `rules_foreign_cc` CMake build of `base64` fails at link
  time:

```
ld.lld: error: unable to find library -lc++
```

### Remaining issue: libc++ not found by linker

The Nix `clang` wrapper (default, non-libc++ variant) does not add
`-L/nix/store/.../libcxx-20.1.8/lib` to the linker search path. While
`llvmPackages_20.libcxx` is in the shell, it only makes the library
available on the filesystem — it doesn't tell clang where to find it.

The `.bazelrc` has `--linkopt -stdlib=libc++` globally (line 7), which
tells clang to link against libc++ instead of libstdc++. But the default
Nix clang wrapper only knows about libstdc++ (from GCC). The linker
cannot find `-lc++`.

**Possible solutions:**

1. **Use `llvmPackages_20.libcxxClang`** instead of `llvmPackages_20.clang`
   in shell.nix. This is a clang wrapper that automatically injects
   `-stdlib=libc++` and the correct `-L` path for libc++. Package exists at
   `/nix/store/...-clang-wrapper-20.1.8` (different derivation from the
   default clang wrapper).

2. **Add `-L` flag explicitly** in `.bazelrc` pointing to the Nix store
   path for libc++. This is fragile (hardcoded Nix store hash).

3. **Use `LIBRARY_PATH` env var** — set
   `LIBRARY_PATH=/nix/store/.../libcxx-20.1.8/lib` in the shellHook, and
   propagate it with `--action_env=LIBRARY_PATH`. The linker checks
   `LIBRARY_PATH` for library search paths.

**Option 1 (libcxxClang) is the most correct** — it is the Nix-idiomatic
way to use clang with libc++.

## Open Questions

1. **Sysroot**: With `system-clang`, the Nix clang wrapper handles sysroot
   resolution automatically (glibc headers, dynamic linker, etc.). The
   custom Ubuntu 22.04 sysroots that Redpanda downloads are not needed.
   However, if there are Ubuntu-specific headers or libraries the build
   depends on, they would need to be provided via Nix packages.

2. **~~libc++ vs libstdc++~~**: RESOLVED — need `libcxxClang` or equivalent.
   See "Remaining issue" above.

3. **Compiler-rt**: Redpanda disables compiler-rt in `.bazelrc`
   (`--@toolchains_llvm//toolchain/config:compiler-rt=False`) and uses
   `--linkopt --unwindlib=libgcc`. The system-clang config doesn't pass
   these flags, so they may need to be added to a `system-clang-nix` config
   variant.

4. **Cross-compilation**: The Nix approach provides native-architecture
   LLVM only. Redpanda's current config supports both x86_64 and aarch64.
   Cross-compilation from Nix would need additional work.

5. **Version match**: nixpkgs has LLVM 20.1.8, which exactly matches
   Redpanda's "current" compiler. The "next" compiler (21.1.6) is not yet
   in nixpkgs (it has up to 21.x but the minor version may differ).

6. **`--action_env=PATH` hermeticity**: Propagating the full host PATH
   into build actions breaks build hermeticity. This is acceptable for a
   dev shell but not for reproducible CI builds. A more hermetic approach
   would construct a minimal PATH containing only the needed tools.

7. **`#!/bin/bash` in rules_python**: The shebang fix in
   `stage1_bootstrap_template.sh` is a patch to rules_python. This should
   be upstreamed — NixOS (and Guix) don't have `/bin/bash`.

## Next Steps

1. Try `llvmPackages_20.libcxxClang` in shell.nix instead of the default
   `llvmPackages_20.clang`
2. Verify the `base64` foreign_cc build links successfully with libc++
3. If that works, attempt a full `//src/v/redpanda:redpanda` build
4. Consider creating a `system-clang-nix` config in `.bazelrc` that includes
   `--action_env=PATH` to avoid passing it manually
