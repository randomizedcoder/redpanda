{
  lib,
  stdenv,
  callPackage,
  runCommand,
  writeShellApplication,
  bazel_8,
  llvmPackages_20,
  python312,
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
  glibc,
  gcc-unwrapped,
  zlib,
  openssl,
  curl,
  lndir,
}:

let
  version = "0.0.0-dev";

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
    rev = "b65ba9d68a489456fa45a924a1726c86fec08e88";
  };

  src = runCommand "redpanda-src-patched" { } ''
    cp -r --no-preserve=mode ${localSrc} $out
    rm -f $out/tools/bazel
    rm -f $out/.bazelversion

    # Embed rules_python in tree
    mkdir -p $out/third_party
    cp -r --no-preserve=mode ${rulesPythonSrc} $out/third_party/rules_python

    # Rewrite local_path_override to in-tree copy
    sed -i 's|path = "/home/das/Downloads/rules_python"|path = "third_party/rules_python"|' $out/MODULE.bazel

    # Add exec_os to skip /etc/os-release detection in the Nix sandbox
    sed -i 's/llvm.toolchain(/llvm.toolchain(\n            exec_os = "linux",/' $out/MODULE.bazel
  '';

  registry = callPackage ./bcr.nix { };

  bazel = bazel_8;
  targets = [ "//src/v/redpanda:redpanda" ];

  nativeBuildInputsDeps = [
    llvmPackages_20.libcxxClang
    llvmPackages_20.lld
    llvmPackages_20.llvm
    llvmPackages_20.libcxx
    python312
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
  ];

  nixPath = lib.makeBinPath (nativeBuildInputsDeps ++ [ bazel stdenv.cc stdenv.cc.bintools ]);

  # Nix store paths for patchelf
  nixInterp = "${glibc}/lib/ld-linux-x86-64.so.2";
  nixRpath = lib.concatStringsSep ":" [
    "${glibc}/lib"
    "${gcc-unwrapped.lib}/lib"
    "${zlib}/lib"
    "${openssl.out}/lib"
    "${curl.out}/lib"
  ];

  # shellcheck-validated script for patching Bazel-downloaded binaries.
  # Fixes two problems in the Nix sandbox:
  #   1. ELF binaries have /lib64/ld-linux-x86-64.so.2 interpreter (doesn't exist)
  #   2. Shell scripts have #!/bin/bash shebang (doesn't exist)
  bazelPatcher = writeShellApplication {
    name = "bazel-sandbox-patcher";
    runtimeInputs = [ patchelf file findutils coreutils gnused ];
    text = ''
      NIX_INTERP="${nixInterp}"
      NIX_RPATH="${nixRpath}"
      NIX_BASH="${bash}/bin/bash"

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

      fix_bash_shebangs() {
        local dir="$1"
        echo "Fixing #!/bin/bash shebangs in $dir..."
        while IFS= read -r -d "" f; do
          local first
          first=$(head -c 11 "$f" 2>/dev/null) || continue
          case "$first" in
            '#!/bin/bash')
              chmod u+w "$f" 2>/dev/null || true
              sed -i "1s|#!/bin/bash|#!$NIX_BASH|" "$f"
              echo "  fixed shebang: $f"
              ;;
          esac
        done < <(find "$dir" -type f \
          \( -name "*.sh" -o -executable \) \
          -print0 2>/dev/null)
      }

      command="''${1:-}"
      shift || true

      case "$command" in
        patch-all)
          for dir in "$@"; do
            if [ -d "$dir" ]; then
              patch_elfs "$dir"
              fix_bash_shebangs "$dir"
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
            [ -d "$dir" ] && fix_bash_shebangs "$dir"
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
    build --action_env=LD_LIBRARY_PATH=${llvmPackages_20.libcxx}/lib:${gccLib}/lib
    build --host_action_env=LD_LIBRARY_PATH=${llvmPackages_20.libcxx}/lib:${gccLib}/lib
    build --linkopt=-Wl,-rpath,${llvmPackages_20.libcxx}/lib
    build --linkopt=-Wl,-rpath,${gccLib}/lib
    build --host_linkopt=-Wl,-rpath,${llvmPackages_20.libcxx}/lib
    build --host_linkopt=-Wl,-rpath,${gccLib}/lib
    build --@protobuf//bazel/toolchains:allow_nonstandard_protoc
  '';

  commonArgs = [
    "--registry=file://${registry}"
    "--shell_executable=${bash}/bin/bash"
    "--action_env=PATH=${nixPath}"
    "--repo_env=PATH=${nixPath}"
    "--repo_env=BAZEL_SH=${bash}/bin/bash"
    "--action_env=BAZEL_SH=${bash}/bin/bash"
    "--repo_env=SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
    "--action_env=SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
    "--spawn_strategy=local"
  ];

  # Patch all Bazel external dirs in the output base
  patchBazelDirs = ''
    ${bazelPatcher}/bin/bazel-sandbox-patcher patch-all \
      "$HOME"/.cache/bazel/_bazel_*/*/external \
      "$HOME"/.cache/bazel/_bazel_*/*/modextwd
  '';

  # Phase 1: FOD that fetches all Bazel dependencies into a repo cache
  bazelRepoCache = stdenv.mkDerivation {
    name = "redpanda-bazel-repo-cache";

    inherit src;
    sourceRoot = "redpanda-src-patched";
    nativeBuildInputs = nativeBuildInputsDeps ++ [ bazel bazelPatcher ];

    outputHash = lib.fakeHash;
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";

    buildPhase = ''
      runHook preBuild

      export HOME=$(mktemp -d)
      mkdir repo_cache

      # Write .bazelrc.nix for the fetch phase
      cat > .bazelrc.nix <<'BAZELRC'
      ${bazelrcNix}
      BAZELRC

      export CC=clang
      export CXX=clang++

      # First fetch: downloads and extracts toolchains. Will fail because
      # downloaded ELF binaries (Rust, Go, etc.) can't execute yet.
      echo "=== Fetch attempt 1 ==="
      ${bazel}/bin/bazel --batch \
        fetch \
        --repository_cache=repo_cache \
        ${lib.escapeShellArgs commonArgs} \
        ${lib.escapeShellArgs targets} || true

      echo "=== Patching downloaded toolchain binaries ==="
      ${patchBazelDirs}

      # Re-fetch with patched binaries. Multiple rounds because Bazel
      # re-creates repo rules (re-extracting from cache, losing patches).
      for attempt in 2 3 4; do
        echo "=== Fetch attempt $attempt ==="
        if ${bazel}/bin/bazel --batch \
          fetch \
          --repository_cache=repo_cache \
          ${lib.escapeShellArgs commonArgs} \
          ${lib.escapeShellArgs targets}; then
          echo "=== Fetch succeeded on attempt $attempt ==="
          break
        fi
        echo "=== Fetch failed, patching again ==="
        ${patchBazelDirs}
      done

      runHook postBuild
    '';

    installPhase = ''
      mkdir -p $out/repo_cache
      if [ "$(ls -A repo_cache/)" ]; then
        cp -r --reflink=auto repo_cache/* $out/repo_cache
      fi
    '';
  };

in
stdenv.mkDerivation {
  name = "redpanda-${version}";
  inherit src version;
  sourceRoot = "redpanda-src-patched";

  nativeBuildInputs = nativeBuildInputsDeps ++ [ bazel bazelPatcher lndir ];

  requiredSystemFeatures = [ "big-parallel" ];

  passthru = {
    bazelRepoCachePath = builtins.unsafeDiscardStringContext (toString bazelRepoCache);
  };

  preBuildPhases = [ "preBuildPhase" ];
  preBuildPhase = ''
    mkdir repo_cache
    ${lndir}/bin/lndir -silent ${bazelRepoCache}/repo_cache repo_cache
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)

    # Write .bazelrc.nix
    cat > .bazelrc.nix <<'BAZELRC'
    ${bazelrcNix}
    BAZELRC

    export CC=clang
    export CXX=clang++

    echo "=== Pre-build patching ==="
    ${patchBazelDirs}

    ${bazel}/bin/bazel --batch \
      build \
      --repository_cache=repo_cache \
      ${lib.escapeShellArgs commonArgs} \
      ${lib.escapeShellArgs targets}

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
