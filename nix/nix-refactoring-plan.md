# Nix Build Infrastructure — Refactoring & Improvement Plan

## Current State

The Nix build infrastructure is ~2,600 lines of Nix + ~780 lines of Python
across 9 `.nix` files and 2 `.py` files. The architecture is sound (linkFarm
repo cache, table-driven nixify rules, persistent output_base), but there is
significant duplication, inline code bloat, and hardcoded values that hurt
maintainability and portability.

Cold build: ~32 min (7,662 actions, 3,103 local compiles).
Warm build: ~5.5 min (100% cache hit after env var sanitization fix).

---

## Part 1: Correctness Fixes

### 1.1 Fix `bench.nix` broken passthru reference

`bench.nix` references `redpandaDrv.passthru.bazelRepoCachePath` but
`redpanda.nix` exposes `passthru = { inherit repoCache; }`. The `clear-bazel`
and `clear-all` bench targets are broken at evaluation time.

**Fix**: Update `bench.nix` to use `passthru.repoCache` or add the expected
attribute to `redpanda.nix`'s passthru.

**Files**: `nix/bench.nix`, `nix/redpanda.nix`
**Effort**: Small

### 1.2 Fix hardcoded x86_64 values

Three places assume x86_64:

1. `nix/nixify-rules.nix` line 20 — hardcoded `ld-linux-x86-64.so.2`
   interpreter. On aarch64, the dynamic linker is `ld-linux-aarch64.so.1`.
   Should derive from `stdenv.hostPlatform`.

2. `nix/redpanda.nix` `bazelrcNix` — hardcoded env var names
   `NIX_CC_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu` and
   `NIX_BINTOOLS_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu`.
   Should derive from the platform triple.

3. `nix/redpanda.nix` `cargoBazel` — hardcoded
   `cargo-bazel-x86_64-unknown-linux-gnu` URL. Should select architecture
   based on `stdenv.hostPlatform`.

**Files**: `nix/nixify-rules.nix`, `nix/redpanda.nix`
**Effort**: Medium

### 1.3 Fix hardcoded local path for rules_python

`redpanda.nix` line 71:
```nix
url = "/home/das/Downloads/rules_python";
```
This only works on one machine. Should be a `fetchFromGitHub` with a pinned
commit, or a flake input.

**Files**: `nix/redpanda.nix` (or `flake.nix` if using flake input)
**Effort**: Small

---

## Part 2: Pre-built Nixpkgs Binaries

### Rationale

Bazel compiles many external tools and libraries from source during the build.
Tools that only produce generated code (not linked into the final binary) are
safe to substitute with pre-built nixpkgs packages — they just need to produce
correct output regardless of their own compilation flags.

For linked libraries, substitution is riskier due to ABI compatibility (Bazel
controls `-std=c++23`, optimization flags, defines). We restrict library
substitution to ForeignCc builds where Bazel already delegates to
CMake/configure and has less control over flags.

### 2.1 Pre-built `protoc` from nixpkgs (HIGHEST IMPACT)

**Current cost**: ~240 compilation actions (protoc compiler + abseil + zlib +
upb, all compiled just to build the protoc tool binary).

**Approach**: Add `protobuf` to `nativeBuildInputs`, configure Bazel to use
the nixpkgs `protoc` via toolchain registration or `--proto_compiler`.

**Version strategy**: Track whatever nixpkgs provides (currently 33.5, exact
match with the pinned Bazel version). Protobuf has a stable ABI and the
generated code is forward-compatible, so minor version drift is acceptable.

**Note**: Redpanda intentionally compiles all protoc language backends (Java,
Python, C#, Kotlin, etc.) because it makes them available for different client
SDKs. The savings here come from not compiling the protoc binary and its
dependencies from source — the language-specific code generation still happens,
just using a pre-built tool.

**Files**: `nix/redpanda.nix`
**Effort**: Medium
**Savings**: ~240 actions, ~2-3 min wall time on cold build

### 2.2 Pre-built ForeignCc dependencies

These are built via `rules_foreign_cc` as monolithic CMake/configure actions.
Each is a single long-running Bazel action. Providing the library from nixpkgs
and wiring it into Bazel's build graph (via `cc_import` or `new_local_repository`)
eliminates the configure+compile step entirely.

| Dependency | Wall time | nixpkgs pkg | Feasibility | Notes |
|---|---|---|---|---|
| **ragel** | 29s | `ragel` | Easy | State machine compiler for Seastar. Single tool binary. |
| **c-ares** | 51s | `c-ares` | Easy | Standard async DNS library. |
| **hwloc** | 72s | `hwloc` | Medium | Hardware locality. Depends on libxml2. |
| **libxml2** | 78s | `libxml2` | Medium | Dependency of hwloc. |
| **openssl** | 118s | `openssl` | Medium | Already a Nix derivation input but Bazel rebuilds it via ForeignCc. |
| **krb5** | 145s | `krb5` | Medium | Complex configure. Need to ensure same features. |

**Total potential savings**: ~495s wall time (overlaps with other work, so
actual reduction depends on critical path).

**Approach for each**: Create a Nix derivation or use the nixpkgs package,
then either:
- Use `new_local_repository` in MODULE.bazel to point Bazel at the pre-built lib
- Patch the relevant `http_archive` / `cmake` rule to use a pre-built version
- For tool-only deps (ragel): just put on PATH and patch the rule that invokes it

**Files**: `nix/redpanda.nix`, `nix/patch-module-bazel.py`, possibly new
`nix/prebuilt-deps.nix`
**Effort**: Medium-Large (each dep is independent, can be done incrementally)

### 2.3 NOT recommended: Pre-built linked C++ libraries

These are compiled by Bazel with specific flags (`-std=c++23`, custom defines,
optimization levels) and linked directly into the redpanda binary. Substituting
with nixpkgs-built versions risks ODR violations or ABI mismatch crashes:

- abseil-cpp, boost, re2, yaml-cpp, fmt, seastar (custom fork), avro (custom fork)

Leave these as Bazel-compiled.

---

## Part 3: DRY / Deduplication

### 3.1 Extract shared `.bazelrc.nix` generator

`redpanda.nix` `bazelrcNix` (lines 407-447) and `shell.nix` shellHook
(lines 63-94) produce nearly identical `.bazelrc.nix` content (~30 shared
lines of `--action_env`/`--host_action_env` pairs).

**Fix**: Create `nix/bazelrc.nix` that takes inputs (nixPath, llvm, gcc, etc.)
and returns the content string. Both files import and call it.

**Files**: New `nix/bazelrc.nix`, `nix/redpanda.nix`, `nix/shell.nix`
**Effort**: Medium

### 3.2 Extract shared build dependency list

`redpanda.nix` `nativeBuildInputsDeps` (lines 250-281) and `shell.nix`
`packages` (lines 30-48) overlap significantly.

**Fix**: Create `nix/common-deps.nix` returning the base list. Both files
import and extend as needed.

**Files**: New `nix/common-deps.nix`, `nix/redpanda.nix`, `nix/shell.nix`
**Effort**: Small

### 3.3 Unify module-shebang data

The module-shebang fix table exists in two places that must stay in sync:
- `nix/nixify-rules.nix` (Nix attribute set, `type = "module-shebangs"`)
- `nix/patch-module-bazel.py` (Python `MODULE_SHEBANG_FIXES` list)

**Fix**: Have `patch-module-bazel.py` accept the shebang fix data as a JSON
argument generated from `nixify-rules.nix`, giving a single source of truth.

**Files**: `nix/nixify-rules.nix`, `nix/patch-module-bazel.py`, `nix/redpanda.nix`
**Effort**: Medium

### 3.4 Deduplicate Go environment variables

Go env vars (`GOPROXY`, `GONOSUMCHECK`, `GONOSUMDB`, `GOFLAGS`) are set both
as `--repo_env` in `commonArgs` and as `export` in `buildPhase`. Both may be
needed (repo_env for Bazel-managed repos, shell env for non-Bazel Go tools)
but should have a comment explaining why, or be consolidated if redundant.

**Files**: `nix/redpanda.nix`
**Effort**: Small

---

## Part 4: Code Cleanup

### 4.1 Remove diagnostics code

The `buildPhase` contains debugging code that adds noise to every build log:

```bash
echo "=== Diagnostics: rules_cc shebang check ==="
for f in ...; do ... done
echo "  BAZEL_SH=$BAZEL_SH"
echo "  /bin/sh exists: ..."
echo "  bash on PATH: ..."
```

Also `diagExternalGlob` (lines 483-486) exists solely for this block.

**Fix**: Remove both.

**Files**: `nix/redpanda.nix`
**Effort**: Small

### 4.2 Extract inline code from `src` runCommand

The source-patching derivation (lines 75-158) contains ~80 lines of inline
bash, Python, and Starlark:
- Inline `python_deps.bzl` Starlark stub (23 lines)
- Inline `repositories.bzl` Python patcher (12 lines)
- Multiple sed commands for `.bazelrc` patching

**Fix**:
- Extract `python_deps.bzl` stub to `nix/python_deps.bzl` (static file, copied in)
- Extract `repositories.bzl` patcher to `nix/patch-repositories-bzl.py`
- Consider consolidating `.bazelrc` sed commands into the Python patcher

**Files**: `nix/redpanda.nix`, new `nix/python_deps.bzl`, new
`nix/patch-repositories-bzl.py`
**Effort**: Medium

### 4.3 Extract `bazelPatcher` to separate script file

The 100-line `writeShellApplication` inline script (lines 294-404) could be
moved to `nix/bazel-sandbox-patcher.sh` and read via `builtins.readFile`, with
Nix string interpolation for the few dynamic values.

**Files**: `nix/redpanda.nix`, new `nix/bazel-sandbox-patcher.sh`
**Effort**: Small

### 4.4 Simplify `nixify-rules.nix` to attrset API

Currently returns a list of typed rules, consumed via `lib.findFirst`. An
attribute set is cleaner and self-documenting:

```nix
# Current (awkward):
patchelfRule = lib.findFirst (r: r.type == "patchelf") null nixifyRules;

# Proposed (direct):
nixifyRules.patchelf.interpreter
nixifyRules.shebangs.interpreters
```

**Files**: `nix/nixify-rules.nix`, `nix/redpanda.nix`
**Effort**: Small

### 4.5 Consolidate `commonArgs` vs `bazelrcNix`

Some Bazel configuration is in `bazelrcNix` (written to `.bazelrc.nix`) and
some in `commonArgs` (CLI flags). There's overlap:
- `--shell_executable` appears in both
- `--action_env=PATH` appears in both

**Fix**: Pick one mechanism. Since `.bazelrc.nix` is already loaded via
`try-import` in `.bazelrc`, prefer putting build-time flags there and keeping
`commonArgs` for flags that must vary per-invocation (like `--repository_cache`).

**Files**: `nix/redpanda.nix`
**Effort**: Medium

---

## Part 5: Minor Improvements

### 5.1 Share version string

Both `redpanda.nix` and `rpk.nix` define `version = "0.0.0-dev"`.

**Fix**: Define once in a shared location.

**Files**: `nix/redpanda.nix`, `nix/rpk.nix`
**Effort**: Trivial

### 5.2 `patchBazelDirs` conditional cleanup

`patchBazelDirs` is an if/else producing two nearly identical shell snippets.
Better: compute paths once in buildPhase and pass as arguments.

**Files**: `nix/redpanda.nix`
**Effort**: Small

### 5.3 Shell.nix missing build-time Python deps

`shell.nix` only includes `kafka-python-ng` but not `jinja2`/`jsonschema`
which are needed for builds. Users running Bazel from the dev shell may hit
confusing errors.

**Fix**: Include build-time Python deps in the dev shell too.

**Files**: `nix/shell.nix`
**Effort**: Trivial

---

## Implementation Order

Suggested order balances impact, risk, and dependency:

| Phase | Items | Rationale |
|---|---|---|
| **A: Quick wins** | 1.1, 4.1, 5.1, 5.3 | Small fixes, no risk, immediate cleanup |
| **B: Correctness** | 1.2, 1.3 | Required for aarch64 and portability |
| **C: Pre-built protoc** | 2.1 | Highest build-time impact (~240 actions) |
| **D: DRY** | 3.1, 3.2, 3.4 | Reduces maintenance burden |
| **E: Code extraction** | 4.2, 4.3, 4.4, 4.5 | Readability, no behavior change |
| **F: Pre-built ForeignCc** | 2.2 (incrementally) | Each dep is independent |
| **G: Remaining** | 3.3, 5.2 | Lower priority cleanup |

Each phase should be a separate commit. Phases A-B are safe to do first
without risking build breakage. Phase C (protoc) should be tested with both
cold and warm builds. Phases D-G are pure refactoring.
