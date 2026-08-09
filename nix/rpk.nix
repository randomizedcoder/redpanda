{
  lib,
  buildGoModule,
  installShellFiles,
}:

let
  version = "0.0.0-dev";
  # Stamp only; not used to fetch. Marks this as the local UDS-enabled build.
  rev = "local-uds";
in
buildGoModule {
  pname = "redpanda-rpk";
  inherit version;

  # Build rpk from the LOCAL source tree so the Kafka UDS listener client
  # support (PR #30240: `unix://` brokers via rewriteUnixBrokers / UDSDialer in
  # pkg/kafka) is included. This previously used `fetchFromGitHub` at an
  # upstream rev that predates the UDS patch, so the built rpk silently lacked
  # `unix://` support while the (locally-built) broker had the UDS listener --
  # producing "unable to parse port from addr" when a client used a unix://
  # seed. `src/go/rpk/go.mod` is a self-contained module (no replace
  # directives), so the source root is the module root.
  src = ../src/go/rpk;

  # Recomputed for the local (rebased-on-dev) go.mod/go.sum; the old value was
  # upstream ae5f867's dependency set and no longer matches.
  vendorHash = "sha256-4Shqj+8or4trXKn6l4q+ouWNTID5hdyVfisEWXrhGiE=";

  ldflags =
    let
      versionPkg = "github.com/redpanda-data/redpanda/src/go/rpk/pkg/cli/version";
      containerPkg = "github.com/redpanda-data/redpanda/src/go/rpk/pkg/cli/container/containerutil";
    in
    [
      "-s" "-w"
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
