{
  mkShell,
  bazelisk,
  llvmPackages_20,
  python312,
  jdk_headless,
  autoconf,
  automake,
  libtool,
  bison,
  pkg-config,
  elfutils,
  git,
  zstd,
}:

mkShell {
  packages = [
    bazelisk
    llvmPackages_20.clang
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
    git
    zstd
  ];

  shellHook = ''
    # Bazelisk reads .bazelversion to pick the right Bazel version.
    # Alias so that "bazel" invokes bazelisk.
    alias bazel=bazelisk

    export CC=clang
    export CXX=clang++

    # Point Bazel at the Nix-provided bash and propagate PATH into the
    # sandbox so that genrules and other actions can find Nix tools.
    # NIX_LDFLAGS/NIX_CFLAGS_COMPILE are used by the Nix clang wrapper.
    cat > .bazelrc.nix <<RCEOF
    build --shell_executable=$(which bash)
    build --action_env=PATH=$PATH
    build --host_action_env=PATH=$PATH
    build --action_env=NIX_LDFLAGS
    build --host_action_env=NIX_LDFLAGS
    build --action_env=NIX_CFLAGS_COMPILE
    build --host_action_env=NIX_CFLAGS_COMPILE
    build --action_env=NIX_CC
    build --host_action_env=NIX_CC
    RCEOF
  '';
}
