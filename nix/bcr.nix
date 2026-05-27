{ fetchFromGitHub }:

# Pinned snapshot of the Bazel Central Registry.
# Must contain all module versions referenced in MODULE.bazel.
# Bumped after dev merge brought in rules_cc 0.2.17, rules_foreign_cc 0.15.1,
# rules_python 1.7.0, rules_rust 0.70.0, toolchains_llvm 1.7.0, wasmtime 42.0.2.
fetchFromGitHub {
  owner = "bazelbuild";
  repo = "bazel-central-registry";
  rev = "d100bb0b0a76b27dd69bb44cfd12165e3c38be91";
  hash = "sha256-v1gV4IfoHIoAq0eKB1nimVrQzREDgW0q0tGZ/fryFMw=";
}
