{
  mkShell,
  bazelisk,
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
  '';
}
