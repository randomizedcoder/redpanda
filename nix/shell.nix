{
  mkShell,
  bazel_8,
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
    bazel_8
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
    # Make Bazelisk (if used) pick the same version as our bazel_8
    export USE_BAZEL_VERSION=${bazel_8.version}
  '';
}
