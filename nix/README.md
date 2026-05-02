# Building Redpanda with Nix

## Quick Start

### Prerequisites

- Nix with flakes enabled (`experimental-features = nix-command flakes` in
  `/etc/nix/nix.conf` or `~/.config/nix/nix.conf`)
- ~20 GB disk for the first build

### System Configuration (nix.conf)

Two additions to `/etc/nix/nix.conf` are required:

1. **`/bin/bash` in sandbox** — Bazel repo rules execute scripts with
   `#!/bin/bash` shebangs, but the Nix sandbox only provides `/bin/sh`.

2. **Persistent Bazel cache passthrough** — allows the sandbox to read/write
   a shared Bazel cache directory so warm builds skip recompilation.

Add both on a single line:

```
extra-sandbox-paths = /bin/bash=/run/current-system/sw/bin/bash /var/cache/bazel-nix
```

If you're not on NixOS, find your bash path with `readlink $(which bash)` and
use that instead. For example:

```
extra-sandbox-paths = /bin/bash=/nix/store/...-bash-5.x/bin/bash /var/cache/bazel-nix
```

NixOS (`configuration.nix`):

```nix
nix.settings.extra-sandbox-paths = [
  "/bin/bash=${pkgs.bash}/bin/bash"
  "/var/cache/bazel-nix"
];
```

After editing, restart the Nix daemon:

```bash
sudo systemctl restart nix-daemon
```

### Create the Bazel Cache Directory

```bash
sudo mkdir -p /var/cache/bazel-nix
sudo chown root:nixbld /var/cache/bazel-nix
sudo chmod 1775 /var/cache/bazel-nix
```

The `nixbld` group ownership and sticky bit allow all Nix builder users to
share the cache while preventing cross-user file deletion.

### Build

```bash
# First build (cold, ~30 min):
nix build .#redpanda-cached --print-build-logs

# Verify:
result/bin/redpanda --version

# Subsequent builds (warm, ~5-6 min):
nix build .#redpanda-cached --print-build-logs
```

Use `redpanda-cached` (not `redpanda`) to get persistent Bazel caching.
The plain `redpanda` target works but does not share cache across builds.

## How It Works

### Two-Derivation Architecture

The Nix build uses two derivations:

1. **Download** (`bazel-repo-cache.nix`) — 365 individual `fetchurl`
   derivations assembled into a content-addressed `linkFarm`. Each archive
   is cached independently in the Nix store, so adding or removing one
   archive only rebuilds that single fetch.

2. **Build** (`redpanda.nix`) — runs Bazel offline using the pre-fetched
   cache. Bazel extracts the archives, the nixify pipeline patches them,
   then Bazel compiles the C++ server.

See [nix-bazel-module-precacher-design.md](nix-bazel-module-precacher-design.md)
for the full design rationale.

### Pre-built Dependencies

13 third-party C/C++ libraries are built from nixpkgs (or from source with
Nix) instead of inside Bazel, saving ~10 minutes of configure/make/cmake
time on cold builds:

| Library | Type | Source |
|---------|------|--------|
| c-ares | static | nixpkgs override |
| krb5 | shared | nixpkgs |
| libxml2 | static | nixpkgs override |
| hwloc | static | nixpkgs override |
| openssl | shared | nixpkgs |
| ragel | binary | nixpkgs |
| xxhash | static | nixpkgs override |
| hdrhistogram | static | nixpkgs |
| croaring | static | nixpkgs override |
| lksctp | static | nixpkgs override |
| ada | static | from source (clang/libc++) |
| base64 | static | from source |
| openssl-fips | shared | from source (FIPS 3.1.2) |

These are injected into Bazel via `new_local_repository` rules that point to
Nix store paths. C++ static libraries must be compiled with clang/libc++ to
match the Bazel toolchain ABI.

### Bazel Cache Persistence

The `redpanda-cached` target passes `--output_base=/var/cache/bazel-nix/output_base`
to Bazel, persisting the action cache across Nix rebuilds. Two environment
variable sanitizations prevent cache key poisoning:

- **`NIX_CFLAGS_COMPILE`** — Nix injects `-frandom-seed=<derivation hash>`
  which changes every build. Bazel already sets its own per-object
  `-frandom-seed`, so the Nix one is stripped.
- **`NIX_LDFLAGS`** — Nix injects `-rpath $out/lib` where `$out` is the
  output store path (changes per derivation). Stripped because the final
  binary gets its rpath from `patchelf` in the install phase.

This achieves 100% action cache hit rate on warm builds (~7,700 actions
cached, 0 recompiles).

### The Fetch-Nixify-Build Loop

Bazel extracts archives and immediately tries to execute downloaded ELF
binaries (Python, Go, protoc, etc.), but these fail in the Nix sandbox
because they have the wrong interpreter and rpath. The build uses a
multi-pass loop:

1. **Fetch** — `bazel fetch` extracts archives from the repo cache (may fail
   when repo rules try to execute unpatched binaries)
2. **Nixify** — patch all ELF binaries in `output_base/external/` with
   `patchelf` (set interpreter + rpath) and fix shebangs (`#!/bin/bash` →
   Nix store bash)
3. **Retry** — run `bazel fetch` again; repeat until all repos resolve
4. **Build** — `bazel build` with all repos nixified

The fixup rules are defined in `nixify-rules.nix`, separate from the build
logic.

### Rust Toolchain

Redpanda depends on Rust (for wasmtime). In Bazel, `rules_rust` normally
downloads a Rust toolchain, but those binaries fail in the Nix sandbox
(wrong ELF interpreter). Instead, the build:

1. **`rust-toolchain.nix`** — assembles a Bazel-compatible Rust toolchain
   by symlinking nixpkgs' `rustc`, `cargo`, `clippy`, and `rustfmt` into
   the directory layout `rules_rust` expects (`bin/`, `lib/`, `lib/rustlib/`).

2. **`patch-module-bazel.py`** — removes the upstream `rust.toolchain()`
   download and replaces it with
   `register_toolchains("//nix_rust:nix_rust_toolchain")`, pointing to
   the Nix-assembled toolchain.

3. **`rust-allocator-shim-patch.cc`** — replaces the `rules_rust` allocator
   library to support Rust 1.89+ where allocator symbols moved into the
   `__rustc::` namespace (Itanium v0 mangling). Provides both old-style
   (`__rust_alloc`) and new-style symbols.

4. **`cargo-bazel-lock.json`** — pre-generated lockfile for `crate.from_cargo()`
   so `rules_rust` treats the crate extension as reproducible and skips
   `cargo-bazel splice` (which needs network access unavailable in the sandbox).

### MODULE.bazel Patching

`patch-module-bazel.py` transforms `MODULE.bazel` for the Nix sandbox.
It is table-driven and operates on the raw text:

**Removed extensions** (not needed for the server build):
- `buildifier_prebuilt`, `rules_shell`, `toolchains_llvm`, `rules_oci`, `pip`

**Modified extensions:**
- `go_sdk` — `go_sdk.download()` → `go_sdk.host()` (use Go from PATH)
- `rust` — remove toolchain download, register nix toolchain
- `crate` — add lockfile path for reproducible evaluation

**Added overrides:**
- `rules_buf` — stub out buf toolchain downloads
- `rules_cc`, `rules_foreign_cc` — fix `#!/bin/bash` shebangs for Nix
- `rules_rust` — skip `cargo-bazel query` (trust pre-generated lockfile)
- `liburing` — clean up source-tree generated files that conflict with
  genrule outputs under `--spawn_strategy=local`
- Pre-built `nix_protoc` toolchain (saves ~240 protoc compilation actions)

### PGO (Profile-Guided Optimization)

Automated three-stage PGO pipeline:

1. **Instrument** — build with `-fprofile-generate` via `pgoMode = "instrument"`
2. **Train** (`pgo-train.nix`) — run a single-node Redpanda with rpk-based
   produce/consume workloads (15,000 messages across 5 size tiers: 64B to
   64KB) to generate LLVM raw profile data
3. **Optimize** — merge profiles with `llvm-profdata`, rebuild with
   `-fprofile-use` via `pgoMode = "optimize"`

```bash
# Fully automated (instrument → train → optimize):
nix build .#redpanda-pgo

# Manual: build instrumented, run your own workload, then optimize:
nix build .#redpanda-pgo-instrument
# ... run workload, collect .profraw files ...
nix build .#redpanda-pgo --override-input pgo-profile ./merged.profdata
```

### Linting

`nix/lint.nix` provides multi-language linting as both `nix run` apps and
`nix flake check` derivations:

| Language | Tools | Command |
|----------|-------|---------|
| Nix | statix, deadnix, nixfmt | `nix run .#lint-nix` |
| Go | gofmt, go vet, golangci-lint | `nix run .#lint-go` |
| Shell | shellcheck, shfmt | `nix run .#lint-shell` |
| C++ | clang-format | `nix run .#lint-cpp` |
| All | all of the above | `nix run .#lint` |

Branch-scoped mode (only lint files changed vs `dev`):

```bash
nix run .#lint -- --branch
```

### Test Framework

The `nix/tests/` directory provides a modular integration test framework
that builds Redpanda, starts a single-node broker, and validates
functionality end-to-end.

#### Architecture

```
nix/tests/
  default.nix              # Orchestrator: wires packages, apps, checks
  lib.nix                  # Bash helpers: color output, timing, counters
  constants.nix            # Ports, timeouts, YAML config templates
  containers.nix           # OCI container image tests (requires Docker)
  smoke.nix                # Minimal broker start/stop test
  single-node.nix          # Full single-node validation (Kafka, admin, rpk)
  lifecycle.nix            # Broker restart, config changes, crash recovery
  uds.nix                  # Unix Domain Socket listener tests
  uds-perf.nix             # UDS vs TCP performance benchmark harness
  checks/                  # Modular check libraries
    kafka-checks.nix       #   Produce/consume, topics, offsets
    admin-checks.nix       #   Admin API health, config, metrics
    rpk-checks.nix         #   rpk CLI commands
    schema-checks.nix      #   Schema Registry CRUD
    proxy-checks.nix       #   HTTP Proxy produce/consume
    resilience-checks.nix  #   Crash recovery, signal handling
    uds-checks.nix         #   UDS listener functionality
    uds-perf-checks.nix    #   UDS benchmark helpers and result tables
```

#### Running Tests

| Target | Command | Description |
|--------|---------|-------------|
| `test-single-node` | `nix run .#test-single-node` | Full single-node validation |
| `test-single-node-cached` | `nix run .#test-single-node-cached` | Same, with Bazel cache |
| `test-lifecycle` | `nix run .#test-lifecycle` | Broker lifecycle tests |
| `test-lifecycle-cached` | `nix run .#test-lifecycle-cached` | Same, with Bazel cache |
| `test-uds` | `nix run .#test-uds` | UDS listener tests |
| `test-uds-cached` | `nix run .#test-uds-cached` | Same, with Bazel cache |
| `test-all` | `nix run .#test-all` | Run all tests |
| `test-all-cached` | `nix run .#test-all-cached` | All tests with Bazel cache |

Tests are also registered as `nix flake check` derivations, so
`nix flake check` runs both lints and integration tests.

## Cache Management

### Clearing Caches

```bash
# Clear Bazel action cache (forces full recompile):
nix run .#clear-bazel

# Clear Nix derivation cache (forces re-fetch + re-nixify):
nix run .#clear-nix

# Clear both (full cold build):
nix run .#clear-all

# Manual equivalent:
sudo rm -rf /var/cache/bazel-nix/*    # Bazel cache
date > nix/entropy                     # Nix cache (changes derivation hash)
```

### Cache Troubleshooting

- **Permission denied on cache** — fix ownership:
  ```bash
  sudo chown -R root:nixbld /var/cache/bazel-nix
  sudo chmod -R g+w /var/cache/bazel-nix
  ```
- **Stale Bazel lock file** — remove it:
  ```bash
  sudo rm /var/cache/bazel-nix/output_base/*.lock
  ```
- **Warm build still recompiling** — check that `-frandom-seed` stripping
  is active in `redpanda.nix` `buildPhase`. Bazel should report ~7,700
  action cache hits with 0 local actions.

## Build Targets

### Packages

| Target | Command | Description |
|--------|---------|-------------|
| `redpanda` | `nix build .#redpanda` | Fastbuild (no optimizations, fastest compile) |
| `redpanda-cached` | `nix build .#redpanda-cached` | Fastbuild with persistent Bazel cache |
| `redpanda-release` | `nix build .#redpanda-release` | `-O2`, security-hardened, stripped |
| `redpanda-release-cached` | `nix build .#redpanda-release-cached` | Release with Bazel cache |
| `redpanda-lto` | `nix build .#redpanda-lto` | ThinLTO cross-module optimization |
| `redpanda-lto-cached` | `nix build .#redpanda-lto-cached` | LTO with Bazel cache |
| `redpanda-pgo` | `nix build .#redpanda-pgo` | Automated PGO (instrument → train → optimize) |
| `redpanda-pgo-cached` | `nix build .#redpanda-pgo-cached` | PGO with Bazel cache |
| `redpanda-pgo-instrument` | `nix build .#redpanda-pgo-instrument` | Instrumented binary for external profiling |
| `rpk` | `nix build .#rpk` | Build the rpk Go CLI from local source |
| `uds-bench-cached` | `nix build .#uds-bench-cached` | Seastar UDS vs TCP micro-benchmarks |

### OCI Container Images

| Target | Command | Description |
|--------|---------|-------------|
| `redpanda-image` | `nix build .#redpanda-image` | Minimal server image |
| `redpanda-image-debug` | `nix build .#redpanda-image-debug` | Server image with bash/coreutils |
| `rpk-image` | `nix build .#rpk-image` | rpk CLI image |

Because the Nix images contain only the exact runtime closure (no package
manager, no extras), they are significantly smaller than the official
Redpanda Docker images:

| Image | Size | Notes |
|-------|------|-------|
| `redpanda:nix` | ~313 MB | vs ~481 MB official (35% smaller) |
| `redpanda:nix-debug` | ~327 MB | adds bash + coreutils |
| `redpanda-rpk:nix` | ~117 MB | rpk built with `-s -w` to strip debug symbols |

The smoke test (`nix run .#test-images`) prints current sizes after loading.

#### Loading and Running

```bash
# Load into Docker:
nix build .#redpanda-image && ./result | docker load

# Run:
docker run -p 9092:9092 -p 9644:9644 -p 8081:8081 -p 8082:8082 \
  redpanda:nix --smp=1 --memory=1G --default-log-level=info

# rpk:
nix build .#rpk-image && ./result | docker load
docker run --net=host redpanda-rpk:nix cluster info
```

### Testing

Run the automated smoke test (requires Docker):

    nix run .#test-images

This builds all three images, starts a redpanda server, verifies Kafka
produce/consume via rpk, and checks the debug image shell. Uses `--net=host`
so ports 9092 and 9644 must be free.

### Dev Shell

```bash
nix develop
```

Provides clang, LLVM, Python, JDK, autotools, and other build tools.
Generates `.bazelrc.nix` with Nix-specific Bazel settings.

### Benchmarking

#### Build Benchmarks

| Target | Command | Description |
|--------|---------|-------------|
| `bench-warm` | `nix run .#bench-warm` | Both caches present |
| `bench-cold-nix` | `nix run .#bench-cold-nix` | Bazel cache present, Nix derivation rebuilt |
| `bench-cold-bazel` | `nix run .#bench-cold-bazel` | Nix derivation cached, Bazel cache cleared |
| `bench-cold-all` | `nix run .#bench-cold-all` | Both caches cleared |
| `bench-3x-warm` | `nix run .#bench-3x-warm` | 3x warm runs |
| `bench-3x-cold-nix` | `nix run .#bench-3x-cold-nix` | 3x cold-nix runs |
| `bench-matrix` | `nix run .#bench-matrix` | Full 9-build matrix |

#### UDS vs TCP Performance Benchmarks

End-to-end Kafka produce/consume benchmarks comparing Unix Domain Socket
(UDS) and TCP loopback transports using `rpk benchmark`. The harness starts
a single-node Redpanda broker with both TCP and UDS Kafka listeners, runs
the same workloads through each transport, and prints comparison tables.

| Target | Command | Description |
|--------|---------|-------------|
| `bench-uds-perf` | `nix run .#bench-uds-perf` | Full matrix (30s/cell, ~20 min) |
| `bench-uds-perf-quick` | `nix run .#bench-uds-perf-quick` | Quick matrix (10s/cell, ~8 min) |
| `bench-uds-perf-cached` | `nix run .#bench-uds-perf-cached` | Full matrix with Bazel cache |
| `bench-uds-perf-quick-cached` | `nix run .#bench-uds-perf-quick-cached` | Quick matrix with Bazel cache |

The benchmark runs three phases:

1. **Produce + Consume** -- async produce through TCP and UDS, then consume
   from the same topics. Sizes: 100 B, 1 kB, 10 kB. Clients: 1, 10, 50
   (50 capped at 1 kB to avoid overwhelming a single-node broker). Topics
   are deleted between pairs to reclaim disk.

2. **Rate-limited produce** -- produce at fixed target rates (10, 50,
   100 MB/s) with 1 kB and 10 kB records. Measures p99 latency and CPU
   usage at controlled throughput levels.

**Results (quick mode, single-node, 2026-05-02):**

Produce throughput (async, batched):

| MsgSize | Clients | TCP req/s | UDS req/s | Ratio |
|---------|---------|-----------|-----------|-------|
| 100 B | 1 | 765,942 | 753,374 | 0.98x |
| 100 B | 10 | 730,718 | 1,042,771 | **1.43x** |
| 100 B | 50 | 1,250,576 | 1,256,862 | 1.00x |
| 1 kB | 1 | 131,806 | 136,084 | 1.03x |
| 10 kB | 1 | 13,188 | 15,632 | **1.19x** |

Consume throughput:

| MsgSize | Clients | TCP MB/s | UDS MB/s | Ratio | TCP p99 | UDS p99 |
|---------|---------|----------|----------|-------|---------|---------|
| 100 B | 10 | 631 | 737 | **1.17x** | 1.02M us | 1.05M us |
| 1 kB | 1 | 188 | 196 | 1.04x | 609K us | **165K us** |
| 10 kB | 1 | 179 | 209 | **1.16x** | 534K us | **249K us** |

Rate-limited produce (p99 latency -- lower is better):

| MsgSize | Rate | TCP p99 | UDS p99 | Ratio |
|---------|------|---------|---------|-------|
| 1 kB | 10 MB/s | 14.4M us | 1.1M us | **0.08x** |
| 1 kB | 50 MB/s | 2.3M us | 518K us | **0.22x** |
| 10 kB | 10 MB/s | 1.3M us | 202K us | **0.15x** |
| 10 kB | 50 MB/s | 621K us | 148K us | **0.24x** |

Key findings:
- **Latency**: UDS p99 is 4-13x lower than TCP at controlled throughput
  (rate-limited tests). This is where UDS provides the clearest advantage.
- **Throughput**: UDS wins at moderate concurrency (10 clients, +17-43%)
  and with single clients on larger messages (+16-19%).
- **Consume**: UDS delivers 2-4x lower p99 latency on single-client reads.
- **High concurrency**: TCP can edge ahead at 50 clients with larger
  messages due to kernel-level connection pooling.

## File Reference

### Core Build Files

| File | Description |
|------|-------------|
| `flake.nix` | Flake entry point; defines packages, apps, dev shell, checks |
| `nix/redpanda.nix` | Main C++ server build derivation (fetch-nixify-build loop) |
| `nix/rpk.nix` | Go CLI package (`buildGoModule` from local source) |
| `nix/shell.nix` | Development shell with clang, LLVM, Python, JDK, autotools |

### Rust Toolchain

| File | Description |
|------|-------------|
| `nix/rust-toolchain.nix` | Assembles nixpkgs Rust into `rules_rust`-compatible layout |
| `nix/rust-allocator-shim-patch.cc` | Allocator shim for Rust 1.89+ `__rustc::` namespace |
| `bazel/thirdparty/cargo-bazel-lock.json` | Pre-generated crate lockfile for offline builds |

### PGO and Optimization

| File | Description |
|------|-------------|
| `nix/pgo-train.nix` | PGO training: instrument → rpk workload → profile merge |

### Testing

| File | Description |
|------|-------------|
| `nix/tests/default.nix` | Test orchestrator: wires packages, apps, checks |
| `nix/tests/lib.nix` | Bash helpers: color output, timing, pass/fail counters |
| `nix/tests/constants.nix` | Ports, timeouts, YAML config templates |
| `nix/tests/smoke.nix` | Minimal broker start/stop |
| `nix/tests/single-node.nix` | Full single-node validation (Kafka, admin, rpk, schema, proxy) |
| `nix/tests/lifecycle.nix` | Broker restart, config changes, crash recovery |
| `nix/tests/uds.nix` | UDS Kafka listener functional tests |
| `nix/tests/uds-perf.nix` | UDS vs TCP performance benchmark harness |
| `nix/tests/containers.nix` | OCI container image tests (requires Docker) |
| `nix/tests/checks/*.nix` | Modular check libraries (kafka, admin, rpk, schema, proxy, resilience, uds, uds-perf) |

### Benchmarking and Linting

| File | Description |
|------|-------------|
| `nix/bench.nix` | Build benchmark and cache-clearing targets |
| `nix/lint.nix` | Multi-language linting (Nix, Go, Shell, C++) |

### OCI Container Images

| File | Description |
|------|-------------|
| `nix/redpanda-image.nix` | OCI container image for the redpanda server |
| `nix/rpk-image.nix` | OCI container image for the rpk CLI |
| `nix/test-images.nix` | OCI container image smoke test |

### Dependency Management

| File | Description |
|------|-------------|
| `nix/bazel-repo-cache.nix` | Builds content-addressed linkFarm from `fetchurl` derivations |
| `nix/bazel-deps.nix` | Generated list of archive URLs and sha256 hashes |
| `nix/bcr.nix` | Pinned Bazel Central Registry snapshot |
| `nix/MODULE.bazel.lock.nix` | Pre-generated lockfile matching patched MODULE.bazel |

### Pre-built Dependency Overrides

| File | Description |
|------|-------------|
| `nix/c-ares-static.nix` | Static c-ares DNS resolver |
| `nix/hwloc-static.nix` | Static hardware locality library (includes hwloc-calc/distrib) |
| `nix/libxml2-static.nix` | Static XML parsing library |
| `nix/xxhash-static.nix` | Static xxHash library |
| `nix/croaring-static.nix` | Static CRoaring bitset library |
| `nix/lksctp-static.nix` | Static SCTP protocol library |
| `nix/ada-static.nix` | Static URL parser (built from source with clang/libc++) |
| `nix/base64-static.nix` | Static base64 encoder/decoder (built from source) |
| `nix/openssl-fips.nix` | FIPS 140-2 provider (OpenSSL 3.1.2, NIST cert #4985) |

### Build Pipeline Scripts

| File | Description |
|------|-------------|
| `nix/nixify-rules.nix` | Configurable ELF/shebang fixup rules for the nixify pipeline |
| `nix/patch-module-bazel.py` | Patches MODULE.bazel for Nix sandbox (table-driven) |
| `nix/gen-bazel-deps.py` | Generates `bazel-deps.nix` from lockfile + BCR + MODULE.bazel |
| `nix/extract-missing-deps.py` | Finds archives in Bazel cache not yet in `bazel-deps.nix` |

### Bazel Patches

| File | Description |
|------|-------------|
| `bazel/thirdparty/liburing.patch` | Out-of-source build fix for liburing in Nix sandbox |
| `nix/patches/rules_buf-nix-no-download.patch` | Stub out buf toolchain downloads |
| `nix/patches/rules_foreign_cc-nix-shebang.patch` | Fix bash shebangs for Nix |

## Design Documentation

- [nix-bazel-module-precacher-design.md](nix-bazel-module-precacher-design.md) —
  Primary design document covering the two-derivation architecture, per-archive
  caching, nixify pipeline, and cache persistence
- [bazel-cache-leak-analysis.md](bazel-cache-leak-analysis.md) —
  Root cause analysis of `-frandom-seed` cache key poisoning
- [STATUS.md](STATUS.md) — Current build status and historical lessons learned
- [sandboxing-build-systems-nix-and-bazel.md](sandboxing-build-systems-nix-and-bazel.md) —
  Architectural comparison of Nix and Bazel sandboxing
- [nix-build-journey.md](nix-build-journey.md) — Historical evolution of
  the build system
- [toolchains-llvm-local-toolchain.md](toolchains-llvm-local-toolchain.md) —
  Using system LLVM/clang instead of downloaded toolchains
- [rules-python-local-toolchain-patch.md](rules-python-local-toolchain-patch.md) —
  Python toolchain Nix compatibility
