{ fetchFromGitHub }:

# Pinned snapshot of the Bazel Central Registry.
# Must contain all module versions referenced in MODULE.bazel.
# Newest BCR-sourced dep: libxml2 2.15.2, fmt 12.1.0, rules_cc 0.2.17
fetchFromGitHub {
  owner = "bazelbuild";
  repo = "bazel-central-registry";
  rev = "feb92cfcd0c0e9fba525aceb8fbfbf9518517674";
  hash = "sha256-yTuLz896B+4YSjvcAvpzjXIXX4bOQ4FvvzMF/NdDEO0=";
}
