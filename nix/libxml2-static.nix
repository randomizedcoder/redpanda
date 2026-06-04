# libxml2-static.nix — Pre-built static libxml2 for Bazel.
#
# Nixpkgs libxml2 ships shared libraries by default. Redpanda's Bazel
# build requires a static libxml2.a (see bazel/thirdparty/libxml2.BUILD).
# This override enables static and disables shared, with zlib support
# (matching the Bazel configure options) and no python/icu/http.
#
# Version is pinned to 2.15.3 to match bazel_dep version in MODULE.bazel
# exactly (nixpkgs ships 2.15.2 as of nixos-unstable 64c08a7c).
{ libxml2, fetchurl }:

(libxml2.override {
  enableStatic = true;
  enableShared = false;
  zlibSupport = true;
  pythonSupport = false;
  icuSupport = false;
  enableHttp = false;
}).overrideAttrs (old: {
  version = "2.15.3";
  src = fetchurl {
    url = "https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.3.tar.xz";
    hash = "sha256-eCYqbnrBcNZSjr/i78zfIgGRpa9qbNYepKmppQQsegc=";
  };
  # testModule tries to dlopen a shared plugin, which doesn't exist
  # in a static-only build. The upstream tests pass with shared libs.
  doCheck = false;
})
