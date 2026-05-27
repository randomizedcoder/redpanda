# libxml2-static.nix — Pre-built static libxml2 for Bazel.
#
# Nixpkgs libxml2 ships shared libraries by default. Redpanda's Bazel
# build requires a static libxml2.a (see bazel/thirdparty/libxml2.BUILD).
# This override enables static and disables shared, with zlib support
# (matching the Bazel configure options) and no python/icu/http.
#
# Version is tracked from nixpkgs (currently 2.15.2, close to the
# bazel_dep version 2.15.3 in MODULE.bazel — same soname ABI).
{ libxml2 }:

(libxml2.override {
  enableStatic = true;
  enableShared = false;
  zlibSupport = true;
  pythonSupport = false;
  icuSupport = false;
  enableHttp = false;
}).overrideAttrs {
  # testModule tries to dlopen a shared plugin, which doesn't exist
  # in a static-only build. The upstream tests pass with shared libs.
  doCheck = false;
}
