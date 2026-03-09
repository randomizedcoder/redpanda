# Extensible fixup rules for nixifying Bazel-extracted repos.
#
# After `bazel fetch` extracts archives into output_base/external/,
# the nixify pipeline applies these rules to make everything work
# in the Nix sandbox.
#
# Rule types:
#   patchelf      — fix ELF interpreter and rpath for Nix sandbox
#   fix-shebangs  — replace hardcoded shebangs with Nix paths
#   patch         — apply patch files to specific module directories
#   substitute    — sed-style replacements in specific files
#
{ lib, bash, glibc, gcc-unwrapped, zlib, openssl, curl }:

let
  nixInterp = "${glibc}/lib/ld-linux-x86-64.so.2";
  nixRpath = lib.concatStringsSep ":" [
    "${glibc}/lib"
    "${gcc-unwrapped.lib}/lib"
    "${zlib}/lib"
    "${openssl.out}/lib"
    "${curl.out}/lib"
  ];
in
[
  # ── Global fixups (applied to ALL extracted repos) ──

  {
    type = "patchelf";
    interpreter = nixInterp;
    rpath = nixRpath;
  }

  {
    type = "fix-shebangs";
    from = "/bin/bash";
    to = "${bash}/bin/bash";
  }

  # ── Per-module patches ──
  # Add entries here as needed, e.g.:
  #
  # {
  #   type = "patch";
  #   module = "rules_cc";
  #   patches = [ ./patches/rules_cc-nix.patch ];
  # }

  # ── Arbitrary substitutions ──
  # {
  #   type = "substitute";
  #   module = "some_module";
  #   file = "some/script.sh";
  #   from = "/usr/bin/python3";
  #   to = "${python3}/bin/python3";
  # }
]
