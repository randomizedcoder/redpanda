{
  lib,
  buildGoModule,
  installShellFiles,
}:

let
  version = "0.0.0-dev";
  # Derived from the working tree at build time. This ensures local
  # source changes under src/go/rpk/ (e.g. the UDS dialer) are compiled
  # into the binary rather than whatever rev was last pinned.
  rev = "dev";
in
buildGoModule {
  pname = "redpanda-rpk";
  inherit version;

  src = lib.cleanSourceWith {
    src = ../.;
    filter =
      path: _type:
      let
        rel = lib.removePrefix (toString ../. + "/") (toString path);
      in
      lib.hasPrefix "src/go/rpk" rel || rel == "src/go" || rel == "src" || rel == "";
  };

  modRoot = "src/go/rpk";
  vendorHash = "sha256-pdg0ZcBynnhaF6E0GQQQxpbcJ6k8dG9tUNlNjn4UYf0=";

  # go.mod pins go 1.26.2 but nixpkgs' Go 1.26 series is currently 1.26.1.
  # The build sandbox has no network for GOTOOLCHAIN=auto to fetch 1.26.2,
  # so relax the patch-version pin to the minor version and strip the
  # toolchain directive. rpk uses no 1.26.2-only features.
  postPatch = ''
    pushd src/go/rpk >/dev/null
    sed -i -E 's/^go [0-9]+\.[0-9]+\.[0-9]+$/go 1.26/' go.mod
    sed -i -E '/^toolchain /d' go.mod
    popd >/dev/null
  '';

  ldflags =
    let
      versionPkg = "github.com/redpanda-data/redpanda/src/go/rpk/pkg/cli/version";
      containerPkg = "github.com/redpanda-data/redpanda/src/go/rpk/pkg/cli/container/containerutil";
    in
    [
      "-s"
      "-w"
      "-X ${versionPkg}.version=${version}"
      "-X ${versionPkg}.rev=${rev}"
      "-X ${containerPkg}.tag=v${version}"
    ];

  nativeBuildInputs = [ installShellFiles ];

  postInstall = ''
    for shell in bash fish zsh; do
      $out/bin/rpk generate shell-completion $shell > rpk.$shell
      installShellCompletion rpk.$shell
    done
  '';

  # Network-dependent tests cannot run in the sandbox
  doCheck = false;

  meta = {
    description = "Redpanda CLI (rpk)";
    homepage = "https://redpanda.com/";
    license = lib.licenses.bsl11;
    platforms = lib.platforms.linux;
    mainProgram = "rpk";
  };
}
