# rust-toolchain.nix — Assemble Bazel-compatible Rust toolchain from nixpkgs.
#
# rules_rust expects a specific directory layout:
#   bin/{rustc,rustdoc,cargo,clippy-driver,cargo-clippy,rustfmt}
#   lib/*.so* (rustc driver libraries)
#   lib/rustlib/<triple>/lib/*.rlib (standard library)
#
# This derivation symlinks nixpkgs' rustc, cargo, clippy, and rustfmt
# into that structure so a Bazel rust_toolchain rule can consume it
# without downloading anything.
{
  runCommand,
  rustc-unwrapped,
  cargo,
  clippy,
  rustfmt,
}:

runCommand "rust-toolchain-bazel" { } ''
  mkdir -p $out/bin $out/lib

  # ── Binaries ──
  ln -s ${rustc-unwrapped}/bin/rustc    $out/bin/rustc
  ln -s ${rustc-unwrapped}/bin/rustdoc  $out/bin/rustdoc
  ln -s ${cargo}/bin/cargo              $out/bin/cargo
  ln -s ${clippy}/bin/clippy-driver     $out/bin/clippy-driver
  ln -s ${clippy}/bin/cargo-clippy      $out/bin/cargo-clippy
  ln -s ${rustfmt}/bin/rustfmt          $out/bin/rustfmt

  # ── rustc driver shared libraries ──
  for f in ${rustc-unwrapped}/lib/*.so*; do
    ln -s "$f" $out/lib/
  done

  # ── rust-std + codegen backends (entire rustlib tree) ──
  # The rustlib directory contains precompiled standard library (.rlib),
  # codegen backends, and target-specific metadata.
  ln -s ${rustc-unwrapped}/lib/rustlib $out/lib/rustlib
''
