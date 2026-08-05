{ fetchFromGitHub }:

# Pinned snapshot of the Bazel Central Registry.
# Must contain all module versions referenced in MODULE.bazel.
# Bumped after the 2026-08-04 dev merge brought in snappy 1.2.2.bcr.3
# (with the export-internal-h patch), abseil-cpp 20250814.1 (clang-23
# lifetime-capture patch), protobuf 33.5, and the clang 23.1.0 toolchain.
fetchFromGitHub {
  owner = "bazelbuild";
  repo = "bazel-central-registry";
  rev = "3f8851eb6c2b42e1aa6addd32dfea14662202f3a";
  hash = "sha256-PpfV5+cHvuWX6gi2zsK9YBPP2G6JziNU3UD8Y1cYxew=";
}
