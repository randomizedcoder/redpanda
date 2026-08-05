# xxhash-static.nix — Pre-built static xxhash for Bazel.
#
# Nixpkgs xxhash uses cmake and only ships shared libraries by default.
# Redpanda's Bazel build requires a static libxxhash.a.
{ xxhash }:

xxhash.overrideAttrs (old: {
  cmakeFlags = (old.cmakeFlags or []) ++ [
    "-DBUILD_SHARED_LIBS=OFF"
  ];
})
