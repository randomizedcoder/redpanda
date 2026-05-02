{
  lib,
  buildGoModule,
  installShellFiles,
}:

let
  version = "0.0.0-dev";
in
buildGoModule {
  pname = "redpanda-rpk";
  inherit version;

  src = ./..;

  modRoot = "src/go/rpk";
  vendorHash = "sha256-pdg0ZcBynnhaF6E0GQQQxpbcJ6k8dG9tUNlNjn4UYf0=";

  ldflags =
    let
      versionPkg = "github.com/redpanda-data/redpanda/src/go/rpk/pkg/cli/version";
      containerPkg = "github.com/redpanda-data/redpanda/src/go/rpk/pkg/cli/container/containerutil";
    in
    [
      "-s" "-w"
      "-X ${versionPkg}.version=${version}"
      "-X ${containerPkg}.tag=v${version}"
    ];

  nativeBuildInputs = [ installShellFiles ];

  postInstall = ''
    for shell in bash fish zsh; do
      $out/bin/rpk generate shell-completion $shell > rpk.$shell
      installShellCompletion rpk.$shell
    done
  '';

  # go.mod requires 1.26.2; nixpkgs ships 1.26.0 via buildGo126Module —
  # minor patch difference is fine, relax the version requirement.
  prePatch = ''
    sed -i 's/^go 1.26.2$/go 1.26.0/' src/go/rpk/go.mod
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
