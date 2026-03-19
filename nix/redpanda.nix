{
  lib,
  stdenv,
  callPackage,
  runCommand,
  writeShellApplication,
  fetchurl,
  bazel_8,
  bazelisk,
  llvmPackages_20,
  python312,
  go,
  jdk_headless,
  autoconf,
  automake,
  libtool,
  bison,
  pkg-config,
  elfutils,
  xfsprogs,
  valgrind,
  patchelf,
  file,
  findutils,
  git,
  cacert,
  zstd,
  coreutils,
  bash,
  gnused,
  gnumake,
  gnugrep,
  gawk,
  perl,
  m4,
  glibc,
  gcc-unwrapped,
  zlib,
  openssl,
  curl,
  lndir,
  protobuf,
  bazelCacheDir ? "",
}:

let
  version = "0.0.0-dev";

  # Python with build-time code generation dependencies (jinja2, jsonschema).
  # Replaces the pip extension — nixpkgs provides the packages directly.
  pythonWithDeps = python312.withPackages (ps: [
    ps.jinja2
    ps.jsonschema
  ]);

  gccLib = stdenv.cc.cc.lib;

  # Local source with filter to exclude build artifacts
  localSrc = lib.cleanSourceWith {
    src = ./..;
    filter = path: type:
      !(builtins.elem (baseNameOf path) [
        ".git" "bazel-bin" "bazel-out" "bazel-redpanda"
        "bazel-testlogs" "result" "result-rpk"
      ]);
  };

  # Fetch the patched rules_python (nix-local-toolchain branch) and
  # embed it in the source tree so local_path_override works in the sandbox.
  rulesPythonSrc = builtins.fetchGit {
    url = "/home/das/Downloads/rules_python";
    ref = "nix-local-toolchain";
    rev = "a9b9c43c62e1fbc14dc162153dc8a5e623f83f3d";
  };

  src = runCommand "redpanda-src-patched" { } ''
    cp -r --no-preserve=mode ${localSrc} $out

    # Embed rules_python in tree
    mkdir -p $out/third_party
    cp -r --no-preserve=mode ${rulesPythonSrc} $out/third_party/rules_python

    # Rewrite local_path_override to in-tree copy
    sed -i 's|path = "/home/das/Downloads/rules_python"|path = "third_party/rules_python"|' $out/MODULE.bazel

    # Create stub @python_deps extension (nixpkgs provides the real packages)
    cat > $out/bazel/python_deps.bzl <<'PYEXT'
"""Stub @python_deps repo for Nix builds.

Creates empty py_library targets for each Python package.
The real packages (jinja2, jsonschema, etc.) are provided by nixpkgs'
python312.withPackages and are on sys.path automatically.
"""

def _python_deps_impl(rctx):
    packages = [
        "jinja2", "jsonschema", "markupsafe",
        "aioboto3", "boto3", "psutil", "pyyaml", "s3transfer",
    ]
    rctx.file("BUILD.bazel", "")
    for pkg in packages:
        rctx.file("{}/BUILD.bazel".format(pkg), 'py_library(name = "{}", visibility = ["//visibility:public"])'.format(pkg))

_python_deps_repo = repository_rule(implementation = _python_deps_impl)

def _python_deps_ext_impl(ctx):
    _python_deps_repo(name = "python_deps")

python_deps_ext = module_extension(implementation = _python_deps_ext_impl)
PYEXT

    # Create nix_protoc/ — pre-built protoc toolchain from nixpkgs.
    # Avoids compiling protoc + abseil + zlib from source (~240 actions).
    mkdir -p $out/nix_protoc/bin
    ln -s ${protobuf}/bin/protoc $out/nix_protoc/bin/protoc
    cat > $out/nix_protoc/BUILD.bazel <<'PROTOC_BUILD'
load("@protobuf//bazel/toolchains:proto_toolchain.bzl", "proto_toolchain")
exports_files(["bin/protoc"])
proto_toolchain(
    name = "nix_protoc",
    proto_compiler = "bin/protoc",
)
PROTOC_BUILD

    # Apply MODULE.bazel patches for Nix sandbox:
    # - Remove unneeded dev extensions (toolchains_llvm, rules_oci, buildifier, rules_shell)
    # - Replace go_sdk.download() with go_sdk.host()
    # - Replace pip extension with nixpkgs stub
    # - Add rules_buf and rules_cc overrides (fix shebangs, stub downloads)
    ${pythonWithDeps}/bin/python3 ${./patch-module-bazel.py} $out/MODULE.bazel

    # Export the patch file so Bazel can resolve the label
    echo 'exports_files(["rules_buf-nix-no-download.patch"])' >> $out/bazel/thirdparty/BUILD

    # Fix openssl Configure shebang: #! /usr/bin/env perl doesn't work in Nix sandbox.
    # Add patch_cmds to both openssl http_archive entries in repositories.bzl.
    # Uses ^#!.* to match ANY shebang variant (resilient to spaces, path differences).
    ${pythonWithDeps}/bin/python3 - $out/bazel/repositories.bzl << 'FIXEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
fix = """        patch_cmds = ["sed -i '1s|^#!.*|#!'$(command -v perl)'|' Configure"],"""
for url in ["openssl-3.5.5.tar.gz", "openssl-3.1.2.tar.gz"]:
    marker = 'url = "https://vectorized-public.s3.amazonaws.com/dependencies/' + url + '",'
    text = text.replace(marker, marker + "\n" + fix)
with open(path, "w") as f:
    f.write(text)
FIXEOF

    # Replace default BCR registry with local copy (the --registry flag is
    # a list flag — CLI values append rather than replace, so we must patch
    # the .bazelrc source to remove the remote URL)
    sed -i 's|common --registry=https://bcr.bazel.build|common --registry=file://${registry}|' $out/.bazelrc

    # Remove .bazelrc lines that reference removed modules
    # (toolchains_llvm, current/next_llvm_toolchain, rules_go, go_sdk)
    sed -i '/^common --@toolchains_llvm/d' $out/.bazelrc
    sed -i '/^common --extra_toolchains=@current_llvm_toolchain/d' $out/.bazelrc
    sed -i '/^common:clang-21 --extra_toolchains=@next_llvm_toolchain/d' $out/.bazelrc
    sed -i '/^build --@rules_go/d' $out/.bazelrc
    sed -i '/^build:gofips/d' $out/.bazelrc
    sed -i '/^build:lto --@rules_rust/d' $out/.bazelrc
    sed -i '/^test:lldb --run_under=.*llvm_toolchain/d' $out/.bazelrc

    # Use pre-generated lockfile that matches the patched MODULE.bazel.
    # Generated by running: bazelisk mod deps --lockfile_mode=update
    # with the same MODULE.bazel patches applied locally.
    # This prevents lockfile staleness from triggering module re-resolution
    # (which would need network access unavailable in the sandbox).
    cp ${./MODULE.bazel.lock.nix} $out/MODULE.bazel.lock
  '';

  registry = callPackage ./bcr.nix { };

  bazel = bazel_8;  # actual binary, used via USE_BAZEL_VERSION
  # Platform-specific wrapper (avoids the generic `bazel` wrapper which
  # re-reads USE_BAZEL_VERSION and double-resolves).
  bazelPlatformBin = let
    os = if stdenv.isLinux then "linux" else "darwin";
    arch = stdenv.hostPlatform.uname.processor;
  in "${bazel}/bin/bazel-8.5.0-${os}-${arch}";
  targets = [ "//src/v/redpanda:redpanda" ];

  # ── Nixify pipeline configuration ──
  # Imported from nixify-rules.nix — centralizes all fixup config.
  nixifyRules = import ./nixify-rules.nix {
    inherit lib bash perl glibc gcc-unwrapped zlib openssl curl;
    python3 = pythonWithDeps;
  };

  # Extract patchelf and shebang config from nixify rules
  patchelfRule = lib.findFirst (r: r.type == "patchelf") null nixifyRules;
  nixInterp = patchelfRule.interpreter;
  nixRpath = patchelfRule.rpath;

  shebangsRule = lib.findFirst (r: r.type == "fix-shebangs") null nixifyRules;
  interpreterMap = shebangsRule.interpreters;

  # Build a sed expression that handles ALL known interpreters in one pass.
  # For each interpreter X with Nix path P, generates a sed branch:
  #   /^#!.*X/{ s|^#!.*|#!P|; }
  # The match is deliberately simple: if line 1 starts with #! and contains
  # the interpreter name ANYWHERE, replace the entire line. No fussy path
  # or spacing patterns — just look for the word. This handles every shebang
  # variant we're ever likely to see:
  #   #!/usr/bin/env perl, #! /bin/perl, #!/usr/local/bin/perl, etc.
  #
  # python3 is checked before python to avoid premature match.
  interpreterSedScript = let
    # Order matters: longer names first so "python3" matches before "python"
    orderedNames = lib.sort (a: b: builtins.stringLength a > builtins.stringLength b)
      (lib.attrNames interpreterMap);
  in lib.concatStringsSep "\n" (
    map (name:
      "/^#!.*${name}/{s|^#!.*|#!${interpreterMap.${name}}|;}"
    ) orderedNames
  );

  # ── Pre-built cargo-bazel for crate_universe extension ──
  # module_ctx.download() does NOT use --repository_cache, so we must
  # provide the binary locally via CARGO_BAZEL_GENERATOR_URL.
  cargoBazel = runCommand "cargo-bazel-patched" {
    nativeBuildInputs = [ patchelf ];
  } ''
    mkdir -p $out/bin
    cp ${fetchurl {
      url = "https://github.com/bazelbuild/rules_rust/releases/download/0.60.0/cargo-bazel-x86_64-unknown-linux-gnu";
      sha256 = "e4f70e4fccedb95cab5efd95ac54953d0e693c05c0552376d542c44df6df6977";
    }} $out/bin/cargo-bazel
    chmod u+wx $out/bin/cargo-bazel
    patchelf --set-interpreter ${nixInterp} --set-rpath ${nixRpath} $out/bin/cargo-bazel
  '';

  # ── Go module proxy cache ──
  # gazelle's go_repository uses fetch_repo which downloads from GOPROXY
  # (proxy.golang.org). This doesn't go through Bazel's --repository_cache.
  # We pre-download the needed Go modules and serve them via GOPROXY=file://.
  # pbgen (Go protobuf code gen) only needs google.golang.org/protobuf and
  # github.com/golang/protobuf.
  goProxyCache = runCommand "go-proxy-cache" { } ''
    mkdir -p $out/google.golang.org/protobuf/@v
    ln -s ${fetchurl { url = "https://proxy.golang.org/google.golang.org/protobuf/@v/v1.36.11.info"; sha256 = "2156715d128777c2a6fae6107d12a0ab60c2b1deed4fba5a2b2481c68911082a"; }} $out/google.golang.org/protobuf/@v/v1.36.11.info
    ln -s ${fetchurl { url = "https://proxy.golang.org/google.golang.org/protobuf/@v/v1.36.11.mod"; sha256 = "a75c105a852fbd8da8d8cfac09c2eab9a206cfd27ed37c973737e23f632ca96e"; }} $out/google.golang.org/protobuf/@v/v1.36.11.mod
    ln -s ${fetchurl { url = "https://proxy.golang.org/google.golang.org/protobuf/@v/v1.36.11.zip"; sha256 = "14983d36c56a814ed91b6d652f2b8f895baba1b84eb43b28a0b132c8637cd274"; }} $out/google.golang.org/protobuf/@v/v1.36.11.zip
    echo '{"Version":"v1.36.11"}' > $out/google.golang.org/protobuf/@v/list

    mkdir -p $out/github.com/golang/protobuf/@v
    ln -s ${fetchurl { url = "https://proxy.golang.org/github.com/golang/protobuf/@v/v1.5.4.info"; sha256 = "840270c813a1c9b8cfe1b66d534336c71dad9da2e1c57c9df3743aaa5eaca219"; }} $out/github.com/golang/protobuf/@v/v1.5.4.info
    ln -s ${fetchurl { url = "https://proxy.golang.org/github.com/golang/protobuf/@v/v1.5.4.mod"; sha256 = "c5f873c621cfaaf563f8b66a0501a5be14390cb0859e5187ce616d0312a6c8f8"; }} $out/github.com/golang/protobuf/@v/v1.5.4.mod
    ln -s ${fetchurl { url = "https://proxy.golang.org/github.com/golang/protobuf/@v/v1.5.4.zip"; sha256 = "9a2f43d3eac8ceda506ebbeb4f229254b87235ce90346692a0e233614182190b"; }} $out/github.com/golang/protobuf/@v/v1.5.4.zip
    echo '{"Version":"v1.5.4"}' > $out/github.com/golang/protobuf/@v/list
  '';

  # ── Per-archive repo cache (linkFarm) ──
  # Each archive is fetched independently via fetchurl, then assembled
  # into a content_addressable/sha256/<hex>/file layout that Bazel
  # recognizes as a repository cache. Adding/removing an archive only
  # rebuilds that single fetchurl — no monolithic FOD hash to manage.
  repoCache = callPackage ./bazel-repo-cache.nix { } {
    archives = import ./bazel-deps.nix;
  };

  nativeBuildInputsDeps = [
    bazelisk
    llvmPackages_20.libcxxClang
    llvmPackages_20.lld
    llvmPackages_20.llvm
    llvmPackages_20.libcxx
    pythonWithDeps
    go
    jdk_headless
    autoconf
    automake
    libtool
    bison
    pkg-config
    elfutils
    xfsprogs
    valgrind
    patchelf
    file
    findutils
    git
    cacert
    zstd
    coreutils
    bash
    gnused
    gnumake
    gnugrep
    gawk
    perl
    m4
  ];

  nixPath = lib.makeBinPath (nativeBuildInputsDeps ++ [ bazel stdenv.cc stdenv.cc.bintools ]);

  # Table-driven script for patching Bazel-downloaded binaries.
  # Fixes two problems in the Nix sandbox:
  #   1. ELF binaries have /lib64/ld-linux-x86-64.so.2 interpreter (doesn't exist)
  #   2. Scripts have shebangs pointing to paths that don't exist in sandbox
  #
  # Shebang handling uses the interpreter map from nixify-rules.nix.
  # A single sed script handles ALL known interpreters in one pass,
  # matching any shebang variant: #!/usr/bin/env X, #! /bin/X,
  # #!/usr/local/bin/X, etc. — resilient to spaces and path differences.
  bazelPatcher = writeShellApplication {
    name = "bazel-sandbox-patcher";
    runtimeInputs = [ patchelf file findutils coreutils gnused ];
    text = ''
      NIX_INTERP="${nixInterp}"
      NIX_RPATH="${nixRpath}"

      # Generated from nixify-rules.nix interpreter map.
      # Each line matches shebangs containing the interpreter name
      # (after a / or space) and replaces the entire shebang line.
      SHEBANG_SED_SCRIPT=$(cat <<'SEDEOF'
      ${interpreterSedScript}
      SEDEOF
      )

      patch_one_elf() {
        local f="$1"
        local desc
        desc=$(file -b "$f" 2>/dev/null) || return 0
        case "$desc" in
          ELF*dynamically\ linked*) ;;
          *) return 0 ;;
        esac
        local interp
        interp=$(patchelf --print-interpreter "$f" 2>/dev/null) || return 0
        case "$interp" in
          /nix/store/*) return 0 ;;
        esac
        echo "  patchelf: $f (was: $interp)"
        chmod u+w "$f" 2>/dev/null || true
        patchelf --set-interpreter "$NIX_INTERP" "$f" 2>/dev/null || true
        local old_rpath
        old_rpath=$(patchelf --print-rpath "$f" 2>/dev/null) || old_rpath=""
        patchelf --set-rpath "$NIX_RPATH:$old_rpath" "$f" 2>/dev/null || true
      }

      patch_elfs() {
        local dir="$1"
        echo "Scanning $dir for ELF binaries to patch..."
        while IFS= read -r -d "" f; do
          patch_one_elf "$f"
        done < <(find -L "$dir" -type f \
          \( -executable -o -name "*.so" -o -name "*.so.*" \) \
          -print0 2>/dev/null)
      }

      fix_shebangs() {
        local dir="$1"
        echo "Fixing shebangs in $dir..."
        while IFS= read -r -d "" f; do
          # Skip binary files
          [[ "$(file -bL --mime-type "$f" 2>/dev/null)" == text/* ]] || continue
          local firstline
          firstline=$(head -n1 "$f" 2>/dev/null) || continue
          # Only process files that have a shebang
          case "$firstline" in
            '#!'*) ;;
            *) continue ;;
          esac
          # Skip files already pointing to /nix/store
          case "$firstline" in
            '#!/nix/store/'*) continue ;;
          esac
          # Apply the table-driven sed script (matches any known interpreter)
          chmod u+w "$(dirname "$f")" 2>/dev/null || true
          chmod u+w "$f" 2>/dev/null || true
          local old="$firstline"
          sed -i "1{$SHEBANG_SED_SCRIPT}" "$f" 2>/dev/null || true
          local new
          new=$(head -n1 "$f" 2>/dev/null) || continue
          if [[ "$old" != "$new" ]]; then
            echo "  fixed shebang: $f ($old -> $new)"
          fi
        done < <(find -L "$dir" \
          -path "*/bazel_tools/*" -prune -o \
          -path "*go_sdk+main___host*" -prune -o \
          -type f \
          \( -name "*.sh" -o -name "*.pl" -o -name "*.py" \
             -o -name "Configure" -o -name "configure" -o -executable \) \
          -print0 2>/dev/null)
      }

      command="''${1:-}"
      shift || true

      case "$command" in
        patch-all)
          for dir in "$@"; do
            if [ -d "$dir" ]; then
              patch_elfs "$dir"
              fix_shebangs "$dir"
            fi
          done
          ;;
        patch-elfs)
          for dir in "$@"; do
            [ -d "$dir" ] && patch_elfs "$dir"
          done
          ;;
        fix-shebangs)
          for dir in "$@"; do
            [ -d "$dir" ] && fix_shebangs "$dir"
          done
          ;;
        *)
          echo "Usage: bazel-sandbox-patcher {patch-all|patch-elfs|fix-shebangs} DIR..."
          exit 1
          ;;
      esac
    '';
  };

  # Generate .bazelrc.nix content (same settings as shell.nix shellHook)
  bazelrcNix = ''
    build --config=system-clang
    build --shell_executable=${bash}/bin/bash
    build --action_env=PATH=${nixPath}
    build --host_action_env=PATH=${nixPath}
    build --action_env=NIX_LDFLAGS
    build --host_action_env=NIX_LDFLAGS
    build --action_env=NIX_CFLAGS_COMPILE
    build --host_action_env=NIX_CFLAGS_COMPILE
    build --action_env=NIX_CC
    build --host_action_env=NIX_CC
    build --action_env=NIX_BINTOOLS
    build --host_action_env=NIX_BINTOOLS
    build --action_env=NIX_CC_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu
    build --host_action_env=NIX_CC_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu
    build --action_env=NIX_BINTOOLS_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu
    build --host_action_env=NIX_BINTOOLS_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu
    build --action_env=NIX_HARDENING_ENABLE
    build --host_action_env=NIX_HARDENING_ENABLE
    build --action_env=NIX_ENFORCE_NO_NATIVE
    build --host_action_env=NIX_ENFORCE_NO_NATIVE
    build --action_env=ACLOCAL_PATH=${lib.concatStringsSep ":" [
      "${automake}/share/aclocal"
      "${libtool}/share/aclocal"
      "${pkg-config}/share/aclocal"
    ]}
    build --host_action_env=ACLOCAL_PATH=${lib.concatStringsSep ":" [
      "${automake}/share/aclocal"
      "${libtool}/share/aclocal"
      "${pkg-config}/share/aclocal"
    ]}
    build --action_env=LIBRARY_PATH=${llvmPackages_20.libcxx}/lib:${gccLib}/lib
    build --host_action_env=LIBRARY_PATH=${llvmPackages_20.libcxx}/lib:${gccLib}/lib
    build --action_env=LD_LIBRARY_PATH=${llvmPackages_20.libcxx}/lib:${gccLib}/lib:${zlib}/lib
    build --host_action_env=LD_LIBRARY_PATH=${llvmPackages_20.libcxx}/lib:${gccLib}/lib:${zlib}/lib
    build --linkopt=-Wl,-rpath,${llvmPackages_20.libcxx}/lib
    build --linkopt=-Wl,-rpath,${gccLib}/lib
    build --host_linkopt=-Wl,-rpath,${llvmPackages_20.libcxx}/lib
    build --host_linkopt=-Wl,-rpath,${gccLib}/lib
    build --@protobuf//bazel/toolchains:allow_nonstandard_protoc
  '';

  commonArgs = [
    "--repository_cache=repo_cache"
    "--shell_executable=${bash}/bin/bash"
    "--action_env=PATH=${nixPath}"
    "--repo_env=PATH=${nixPath}"
    "--repo_env=BAZEL_SH=${bash}/bin/bash"
    "--action_env=BAZEL_SH=${bash}/bin/bash"
    "--repo_env=SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
    "--action_env=SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
    "--repo_env=GOPROXY=file://${goProxyCache},off"
    "--repo_env=GONOSUMCHECK=*"
    "--repo_env=GONOSUMDB=*"
    "--repo_env=GOFLAGS=-modcacherw"
    "--spawn_strategy=local"
  ];

  # Startup flags (before the subcommand) — forces Bazel to use the
  # persistent cache directory instead of computing one from MD5(workspace_path).
  bazelStartupArgs = lib.optionals (bazelCacheDir != "") [
    "--output_base=${bazelCacheDir}/output_base"
  ];

  # Patch all Bazel external dirs in the output base
  patchBazelDirs = if bazelCacheDir != "" then ''
    ${bazelPatcher}/bin/bazel-sandbox-patcher patch-all \
      "${bazelCacheDir}/output_base/external" \
      "${bazelCacheDir}/output_base/modextwd"
  '' else ''
    ${bazelPatcher}/bin/bazel-sandbox-patcher patch-all \
      "$HOME"/.cache/bazel/_bazel_*/*/external \
      "$HOME"/.cache/bazel/_bazel_*/*/modextwd
  '';

in
stdenv.mkDerivation {
  name = "redpanda-${version}";
  inherit src version;
  sourceRoot = "redpanda-src-patched";

  nativeBuildInputs = nativeBuildInputsDeps ++ [ bazel bazelPatcher lndir ];

  requiredSystemFeatures = [ "big-parallel" ];

  passthru = {
    inherit repoCache;
  };

  buildPhase = ''
    runHook preBuild

    export HOME=/tmp/bazel-home
    mkdir -p $HOME

    # ── Sanitize Nix stdenv env vars for Bazel cache stability ──
    # Nix injects derivation-hash-dependent values into these env vars:
    #   NIX_CFLAGS_COMPILE: -frandom-seed=<output-hash-prefix>
    #   NIX_LDFLAGS: -rpath <output-store-path>/lib
    # Since these are passed to Bazel via --action_env, they become part of
    # every action's cache key. When the derivation hash changes (e.g. touching
    # nix/entropy), ALL compilation actions get new cache keys → 100% miss.
    # Stripping these is safe:
    #   - Bazel sets its own per-object -frandom-seed in command args
    #   - The $out rpath is meaningless inside Bazel (patchelf fixes it later)
    export NIX_CFLAGS_COMPILE="$(echo "$NIX_CFLAGS_COMPILE" | sed 's/-frandom-seed=[^[:space:]]*//')"
    export NIX_LDFLAGS="$(echo "$NIX_LDFLAGS" | sed 's|-rpath /nix/store/[^[:space:]]*/lib[[:space:]]*||')"

    # Write .bazelrc.nix
    cat > .bazelrc.nix <<'BAZELRC'
    ${bazelrcNix}
    BAZELRC

    export CC=clang
    export CXX=clang++

    # Point bazelisk at the nixpkgs bazel_8 platform wrapper (no runtime
    # download). Must NOT point to the generic `bazel` wrapper — it re-reads
    # USE_BAZEL_VERSION and double-resolves.
    export USE_BAZEL_VERSION=${bazelPlatformBin}

    # Bazel needs to find bash for patch_cmds, repo rule shell commands, etc.
    # --repo_env only makes it available to repository_ctx.os.environ, but
    # patch_cmds (module resolution phase) reads the process environment.
    export BAZEL_SH=${bash}/bin/bash

    # Provide cargo-bazel binary for crate_universe extension evaluation.
    # module_ctx.download() doesn't use --repository_cache, so we provide
    # a pre-built, patchelf'd binary via env var (file:// URL).
    # The path must match what's recorded in the lockfile to prevent
    # extension re-evaluation (which would need cargo + crate index).
    cp ${cargoBazel}/bin/cargo-bazel /tmp/cargo-bazel
    chmod +x /tmp/cargo-bazel
    export CARGO_BAZEL_GENERATOR_URL=file:///tmp/cargo-bazel

    # Disable canonical ID so Bazel uses pure content-addressing
    export BAZEL_HTTP_RULES_URLS_AS_DEFAULT_CANONICAL_ID=0

    # Tell cargo not to access the network (crate sources are in repo cache,
    # cargo-bazel splice only needs the lockfile metadata).
    export CARGO_NET_OFFLINE=true

    # Go module proxy cache for gazelle's go_repository rules.
    # fetch_repo uses GOPROXY, not Bazel's --repository_cache.
    export GOPROXY=file://${goProxyCache},off
    export GONOSUMCHECK='*'
    export GONOSUMDB='*'
    export GOFLAGS=-modcacherw

    # Create a writable copy of the repo cache. The linkFarm is in the
    # read-only Nix store, but Bazel needs to write to the cache dir
    # (e.g. caching registry file lookups). lndir creates a writable
    # directory tree with symlinks to the actual archive files.
    mkdir -p repo_cache
    ${lndir}/bin/lndir -silent ${repoCache} repo_cache

    # ── Phase A: Initial fetch ──
    # Extracts archives from the pre-populated repo cache.
    # Will fail because downloaded ELF binaries (Rust, Go, etc.)
    # can't execute in the Nix sandbox without patching.
    echo "=== Fetch attempt 1 ==="
    bazelisk \
      ${lib.escapeShellArgs bazelStartupArgs} \
      fetch \
      --keep_going \
      ${lib.escapeShellArgs commonArgs} \
      ${lib.escapeShellArgs targets} || true

    # ── Phase B+C: Nixify + re-fetch loop ──
    # Patch extracted binaries, then re-fetch. Multiple rounds because
    # Bazel may re-extract archives (losing patches) when repo rules
    # re-run with now-working binaries.
    for attempt in 2 3 4; do
      echo "=== Nixify pass (before attempt $attempt) ==="
      ${patchBazelDirs}

      echo "=== Fetch attempt $attempt ==="
      if bazelisk \
        ${lib.escapeShellArgs bazelStartupArgs} \
        fetch \
        --keep_going \
        ${lib.escapeShellArgs commonArgs} \
        ${lib.escapeShellArgs targets}; then
        echo "=== Fetch succeeded on attempt $attempt ==="
        break
      fi
    done

    # Final nixify pass before build
    echo "=== Final nixify pass ==="
    ${patchBazelDirs}

    # ── Phase D: Build ──
    bazelisk \
      ${lib.escapeShellArgs bazelStartupArgs} \
      build \
      --verbose_failures \
      ${lib.escapeShellArgs commonArgs} \
      ${lib.escapeShellArgs targets}

    # Shut down the persistent server
    bazelisk ${lib.escapeShellArgs bazelStartupArgs} shutdown || true

    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out/bin $out/etc/redpanda
    install -m755 bazel-bin/src/v/redpanda/redpanda $out/bin/redpanda
    install -m644 conf/redpanda.yaml $out/etc/redpanda/redpanda.yaml
  '';

  meta = {
    description = "Redpanda: a Kafka-compatible streaming data platform";
    homepage = "https://redpanda.com/";
    license = lib.licenses.bsl11;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "redpanda";
  };
}
