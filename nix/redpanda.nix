{
  lib,
  stdenv,
  callPackage,
  fetchFromGitHub,
  runCommand,
  bazel_8,
  jdk_headless,
  python313,
  cargo-bazel,
  rustc,
  cargo,
  autoconf,
  automake,
  libtool,
  bison,
  pkg-config,
  elfutils,
  patchelf,
  file,
  findutils,
  git,
  cacert,
  zstd,
  coreutils,
  bash,
  gnused,
  bubblewrap,
  glibc,
  gcc-unwrapped,
  zlib,
  openssl,
  curl,
  buildEnv,
  lndir,
  nixpkgsSrc,
}:

let
  version = "0.0.0-dev";
  rev = "ae5f867664a0160428d904a6c9ee835d4f979bd1";

  rawSrc = fetchFromGitHub {
    owner = "redpanda-data";
    repo = "redpanda";
    inherit rev;
    hash = "sha256-lt0z25GBSq6aqiuE4Cedjpe3rxSa7wmve5tFv1gnzHo=";
  };

  # Patch the source for Nix sandbox compatibility:
  # - Remove tools/bazel (Bazelisk wrapper with /usr/bin/env shebang)
  # - Remove .bazelversion (nixpkgs bazel_8 may be a newer patch version)
  # - Add exec_os = "linux" to toolchains_llvm config to skip /etc/os-release
  #   detection which doesn't exist in the Nix sandbox
  src = runCommand "redpanda-src-patched" { } ''
    cp -r --no-preserve=mode ${rawSrc} $out
    rm -f $out/tools/bazel
    rm -f $out/.bazelversion
    # Add exec_os to skip /etc/os-release detection in the Nix sandbox
    sed -i 's/llvm.toolchain(/llvm.toolchain(\n            exec_os = "linux",/' $out/MODULE.bazel
  '';

  registry = callPackage ./bcr.nix { };

  bazel = bazel_8;
  targets = [ "//src/v/redpanda:redpanda" ];

  nativeBuildInputsDeps = [
    jdk_headless
    python313
    cargo-bazel
    rustc
    cargo
    autoconf
    automake
    libtool
    bison
    pkg-config
    elfutils
    patchelf
    file
    findutils
    git
    cacert
    zstd
    coreutils
    bash
    gnused
    bubblewrap
  ];

  nixPath = lib.makeBinPath (nativeBuildInputsDeps ++ [ stdenv.cc stdenv.cc.bintools ]);

  commonArgs = [
    "--config=release"
    # Tell Bazel where bash is (process wrapper, shell actions, genrules)
    "--shell_executable=${bash}/bin/bash"
    # Override .bazelrc's --incompatible_strict_action_env for repo rules
    "--action_env=PATH=${nixPath}:/usr/bin:/bin"
    "--repo_env=PATH=${nixPath}:/usr/bin:/bin"
    "--repo_env=BAZEL_SH=${bash}/bin/bash"
    "--action_env=BAZEL_SH=${bash}/bin/bash"
    # Provide SSL certs for cargo/curl used by repo rules
    "--repo_env=SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
    "--action_env=SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
    # Use Nix-provided cargo-bazel instead of downloading a pre-built binary
    "--repo_env=CARGO_BAZEL_GENERATOR_URL=file://${cargo-bazel}/bin/cargo-bazel"
    # Provide Nix cargo/rustc for cargo-bazel to use (the downloaded Rust
    # toolchain binaries are pre-built ELFs that can't run in the sandbox)
    "--repo_env=CARGO=${cargo}/bin/cargo"
    "--repo_env=RUSTC=${rustc}/bin/rustc"
    "--action_env=CARGO=${cargo}/bin/cargo"
    "--action_env=RUSTC=${rustc}/bin/rustc"
    # Disable Bazel's linux-sandbox: it creates a nested mount namespace
    # that doesn't inherit bwrap's /lib64 mount, preventing pre-built
    # ELF binaries from executing. We already have bwrap for isolation.
    "--spawn_strategy=local"
    "--sandbox_debug"
  ];

  # Merged library directory providing glibc, zlib, libstdc++, etc. for
  # pre-built ELF binaries that Bazel downloads (Python, Rust, Go toolchains).
  # After patchelf sets their interpreter to /lib64/ld-linux-x86-64.so.2 and
  # adds /lib64 to RPATH, these libraries become available.
  fhsLibs = buildEnv {
    name = "redpanda-fhs-libs";
    paths = [
      "${glibc}/lib"
      "${gcc-unwrapped.lib}/lib"
      "${zlib}/lib"
      "${openssl.out}/lib"
      "${curl.out}/lib"
    ];
    pathsToLink = [ "/lib" ];
  };

  # Merged /bin with bash + sh + python + coreutils, and /usr/bin with env
  fhsBin = runCommand "redpanda-fhs-bin" { } ''
    mkdir -p $out/bin $out/usr/bin
    ln -s ${bash}/bin/bash $out/bin/bash
    ln -s ${bash}/bin/bash $out/bin/sh
    ln -s ${coreutils}/bin/env $out/usr/bin/env
    # Provide common coreutils in /bin for scripts and tests
    for cmd in ls cat cp mv rm mkdir readlink stat uname; do
      ln -s ${coreutils}/bin/$cmd $out/bin/$cmd
    done
    ln -s ${python313}/bin/python3 $out/bin/python3
    ln -s ${python313}/bin/python3 $out/bin/python
  '';

  # Minimal /etc for the bwrap namespace (static parts only)
  fhsEtc = runCommand "redpanda-fhs-etc" { } ''
    mkdir -p $out/ssl/certs
    echo "nixbld:x:$(id -u):$(id -g):nixbld:/build:/bin/bash" > $out/passwd
    echo "nixbld:x:$(id -g):" > $out/group
    echo "hosts: files dns" > $out/nsswitch.conf
    echo "127.0.0.1 localhost" > $out/hosts
    # SSL certificates
    ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt $out/ssl/certs/ca-certificates.crt
    ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt $out/ssl/certs/ca-bundle.crt
  '';

  # Construct a bwrap invocation that creates a new root with FHS layout.
  # The Nix sandbox has a read-only root without /lib64 or /usr, so we
  # build a new root from scratch instead of using --dev-bind / /.
  # Without --dev-bind, bwrap creates a tmpfs root and can mkdir freely.
  bwrapBazel = builtins.concatStringsSep " " [
    "${bubblewrap}/bin/bwrap"
    "--ro-bind /nix /nix"
    "--bind /build /build"
    "--bind /tmp /tmp"
    "--dev /dev"
    "--proc /proc"
    "--ro-bind ${fhsLibs}/lib /lib64"
    "--ro-bind ${fhsBin}/bin /bin"
    "--ro-bind ${fhsBin}/usr/bin /usr/bin"
    # Mount our static /etc; resolv.conf is added at build time via
    # a pre-bwrap step that merges fhsEtc + sandbox's resolv.conf
    "--ro-bind $BWRAP_ETC /etc"
    "--tmpfs /run"
    "--tmpfs /var"
    "--setenv USER nixbld"
    "--chdir $PWD"
    "--die-with-parent"
    "--"
    "${bazel}/bin/bazel --batch"
  ];

  # Phase 1: FOD that fetches all Bazel dependencies into a repo cache
  bazelRepoCache = stdenv.mkDerivation {
    name = "redpanda-bazel-repo-cache";

    inherit src;
    sourceRoot = "redpanda-src-patched";
    nativeBuildInputs = nativeBuildInputsDeps;

    outputHash = {
      x86_64-linux = lib.fakeHash;
      aarch64-linux = lib.fakeHash;
    }.${stdenv.hostPlatform.system};
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";

    buildPhase = ''
      runHook preBuild

      export HOME=$(mktemp -d)
      mkdir repo_cache

      # Merge static /etc with sandbox's resolv.conf for DNS inside bwrap
      export BWRAP_ETC=$(mktemp -d)
      cp -r ${fhsEtc}/* $BWRAP_ETC/
      [ -f /etc/resolv.conf ] && cp /etc/resolv.conf $BWRAP_ETC/resolv.conf

      # Nix store paths for patchelf: set interpreter and RPATH to point at
      # actual Nix store libraries instead of /lib64 (bwrap mounts don't work)
      NIX_INTERP="${glibc}/lib/ld-linux-x86-64.so.2"
      NIX_RPATH="${glibc}/lib:${gcc-unwrapped.lib}/lib:${zlib}/lib:${openssl.out}/lib:${curl.out}/lib"

      # Helper: patch a single ELF binary to use Nix store interpreter.
      patch_one_elf() {
        local f="$1"
        local desc
        desc=$(${file}/bin/file -b "$f" 2>/dev/null) || return 0
        case "$desc" in
          ELF*dynamically\ linked*) ;;
          *) return 0 ;;
        esac
        local interp
        interp=$(${patchelf}/bin/patchelf --print-interpreter "$f" 2>/dev/null) || return 0
        case "$interp" in
          /nix/store/*) return 0 ;;
        esac
        echo "  patchelf: $f (was: $interp)"
        chmod u+w "$f" 2>/dev/null || true
        ${patchelf}/bin/patchelf --set-interpreter "$NIX_INTERP" "$f" 2>/dev/null || true
        # Use --set-rpath to prepend Nix paths before the original RPATH
        local old_rpath
        old_rpath=$(${patchelf}/bin/patchelf --print-rpath "$f" 2>/dev/null) || old_rpath=""
        ${patchelf}/bin/patchelf --set-rpath "$NIX_RPATH:$old_rpath" "$f" 2>/dev/null || true
      }

      # Helper: patch all pre-built ELF binaries under a directory tree.
      patch_elfs() {
        local dir="$1"
        echo "Scanning $dir for ELF binaries to patch..."
        local f
        while IFS= read -r -d "" f; do
          patch_one_elf "$f"
        done < <(${findutils}/bin/find -L "$dir" -type f \
          \( -executable -o -name "*.so" -o -name "*.so.*" \) \
          -print0 2>/dev/null)
      }

      # Test: verify /lib64 mount works inside bwrap
      echo "=== Testing bwrap /lib64 mount ==="
      ${bubblewrap}/bin/bwrap \
        --ro-bind /nix /nix \
        --bind /build /build \
        --bind /tmp /tmp \
        --dev /dev \
        --proc /proc \
        --ro-bind ${fhsLibs}/lib /lib64 \
        --ro-bind ${fhsBin}/bin /bin \
        --ro-bind ${fhsBin}/usr/bin /usr/bin \
        --ro-bind $BWRAP_ETC /etc \
        --tmpfs /run \
        --tmpfs /var \
        --setenv USER nixbld \
        --die-with-parent \
        -- ${coreutils}/bin/ls -la /lib64/ld-linux-x86-64.so.2 || echo "FAILED: /lib64/ld-linux-x86-64.so.2 not found in bwrap!"

      # First fetch: downloads and extracts all toolchains. Will fail
      # because downloaded ELF binaries can't execute yet.
      ${bwrapBazel} \
        fetch \
        --registry=file://${registry} \
        --repository_cache=repo_cache \
        ${lib.escapeShellArgs commonArgs} \
        ${lib.escapeShellArgs targets} || true

      # Debug: list what repos exist after first fetch
      echo "=== Listing downloaded repos ==="
      for bazel_base in $HOME/.cache/bazel/_bazel_*/*/external; do
        if [ -d "$bazel_base" ]; then
          echo "Repos in $bazel_base:"
          ls -d "$bazel_base"/rules_python* "$bazel_base"/rules_rust* 2>/dev/null | head -20
          echo "---"
          # Check if the python platform repo has a binary
          for pyrepo in "$bazel_base"/rules_python++python+python_3_12_*; do
            if [ -d "$pyrepo" ]; then
              echo "Python repo: $pyrepo"
              ls -la "$pyrepo/bin/" 2>/dev/null | head -10
              ls -la "$pyrepo/python" 2>/dev/null
              ${file}/bin/file "$pyrepo/bin/python3" 2>/dev/null || true
              ${file}/bin/file "$pyrepo/bin/python3.12" 2>/dev/null || true
              ${patchelf}/bin/patchelf --print-interpreter "$pyrepo/bin/python3.12" 2>/dev/null && echo "(has interpreter)" || echo "(no interpreter / not ELF)"
            fi
          done
          # Check rust repos
          for rustrepo in "$bazel_base"/rules_rust++rust_host_tools*; do
            if [ -d "$rustrepo" ]; then
              echo "Rust host tools: $rustrepo"
              ls -la "$rustrepo/bin/" 2>/dev/null | head -10
              ${file}/bin/file "$rustrepo/bin/cargo" 2>/dev/null || true
              ${patchelf}/bin/patchelf --print-interpreter "$rustrepo/bin/cargo" 2>/dev/null && echo "(has interpreter)" || echo "(no interpreter / not ELF)"
            fi
          done
          for rustrepo in "$bazel_base"/rules_rust++rust+rust_linux*; do
            if [ -d "$rustrepo" ]; then
              echo "Rust platform tools: $rustrepo"
              ls -la "$rustrepo/bin/" 2>/dev/null | head -10
              ${file}/bin/file "$rustrepo/bin/cargo" 2>/dev/null || true
            fi
          done
        fi
      done

      # Patch ALL downloaded pre-built ELF binaries so they can execute
      # inside our bwrap namespace. This fixes Python, Rust, Go, etc.
      echo "=== Patching downloaded toolchain binaries ==="
      for bazel_cache in $HOME/.cache/bazel/_bazel_*/*/external; do
        if [ -d "$bazel_cache" ]; then
          patch_elfs "$bazel_cache"
        fi
      done
      # Also patch module extension working directory binaries (cargo-bazel)
      for modext in $HOME/.cache/bazel/_bazel_*/*/modextwd; do
        if [ -d "$modext" ]; then
          patch_elfs "$modext"
        fi
      done

      # Verify patchelf worked on key binaries
      echo "=== Verifying patched binaries ==="
      for cargo_bin in $HOME/.cache/bazel/_bazel_*/*/external/rules_rust++rust_host_tools+rust_host_tools/bin/cargo; do
        if [ -f "$cargo_bin" ]; then
          echo "cargo interpreter: $(${patchelf}/bin/patchelf --print-interpreter "$cargo_bin" 2>/dev/null)"
          echo "cargo rpath: $(${patchelf}/bin/patchelf --print-rpath "$cargo_bin" 2>/dev/null)"
          echo "cargo test: $("$cargo_bin" --version 2>&1)" || true
        fi
      done
      for py_bin in $HOME/.cache/bazel/_bazel_*/*/external/rules_python++python+python_3_12_x86_64-*/bin/python3.12; do
        if [ -f "$py_bin" ]; then
          echo "python interpreter: $(${patchelf}/bin/patchelf --print-interpreter "$py_bin" 2>/dev/null)"
          echo "python rpath: $(${patchelf}/bin/patchelf --print-rpath "$py_bin" 2>/dev/null)"
          echo "python test: $("$py_bin" --version 2>&1)" || true
        fi
      done

      # Re-run fetch with patched binaries. May need multiple rounds
      # because Bazel re-creates repo rules (which re-copy binaries from
      # cached archives, losing our patches). Each round patches any newly
      # created unpatched binaries.
      for attempt in 2 3 4; do
        echo "=== Fetch attempt $attempt ==="
        if ${bwrapBazel} \
          fetch \
          --registry=file://${registry} \
          --repository_cache=repo_cache \
          ${lib.escapeShellArgs commonArgs} \
          ${lib.escapeShellArgs targets}; then
          echo "=== Fetch succeeded on attempt $attempt ==="
          break
        fi
        echo "=== Fetch failed, patching again ==="
        for bazel_cache in $HOME/.cache/bazel/_bazel_*/*/external; do
          [ -d "$bazel_cache" ] && patch_elfs "$bazel_cache"
        done
        for modext in $HOME/.cache/bazel/_bazel_*/*/modextwd; do
          [ -d "$modext" ] && patch_elfs "$modext"
        done
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

  nativeBuildInputs = nativeBuildInputsDeps;

  requiredSystemFeatures = [ "big-parallel" ];

  preBuildPhases = [ "preBuildPhase" ];
  preBuildPhase = ''
    mkdir repo_cache
    ${lndir}/bin/lndir -silent ${bazelRepoCache}/repo_cache repo_cache
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)

    # Merge static /etc with sandbox's resolv.conf for DNS inside bwrap
    export BWRAP_ETC=$(mktemp -d)
    cp -r ${fhsEtc}/* $BWRAP_ETC/
    [ -f /etc/resolv.conf ] && cp /etc/resolv.conf $BWRAP_ETC/resolv.conf

    ${bwrapBazel} \
      build \
      --registry=file://${registry} \
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
