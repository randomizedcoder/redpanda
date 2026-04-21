# nix/tests/uds.nix
#
# Layer 2+: UDS-specific integration test. Brings up a Redpanda broker
# with a mixed-transport Kafka listener (TCP + AF_UNIX) and exercises:
#   - socket on-disk invariants (exists, mode, lockfile)
#   - pure-UDS produce/consume round-trip
#   - cross-transport produce/consume (mixed-transport is the default
#     production shape, not an edge case)
#   - graceful shutdown cleanup (socket + lockfile both unlinked)
#   - stale-socket recovery (broker starts cleanly over a dead inode)
#
# Kept as a separate test (not folded into single-node.nix) so a UDS
# regression does not block the core suite during rollout.
# Run with: nix run .#test-uds
{
  pkgs,
  redpandaDrv,
  rpkDrv,
}:

let
  testLib = import ./lib.nix { inherit redpandaDrv rpkDrv; };
  inherit (testLib) constants;
  udsChecks = import ./checks/uds-checks.nix { inherit rpkDrv constants; };

  udsMode = "0660";
in
pkgs.writeShellApplication {
  name = "test-uds";
  runtimeInputs = with pkgs; [
    coreutils
    gnugrep
    gnused
    curl
    jq
    python3
    redpandaDrv
    rpkDrv
  ];
  text = ''
    set +e

    ${testLib.colorHelpers}
    ${testLib.timingHelpers}
    ${testLib.counterHelpers}
    ${testLib.processHelpers}
    ${testLib.assertionHelpers}

    TOTAL_START=$(time_ms)

    WORK=$(mktemp -d)
    DATA_DIR="$WORK/data"
    CONFIG="$WORK/redpanda.yaml"
    # Keep the socket path short — sun_path is 108 bytes on Linux,
    # /tmp mktemp dirs eat ~25-40 of that before the filename.
    SOCK_PATH="$WORK/rp.sock"
    export SOCK_PATH WORK CONFIG
    mkdir -p "$DATA_DIR"

    cleanup() {
      if [[ -n "''${RP_PID:-}" ]]; then
        kill -TERM "$RP_PID" 2>/dev/null || true
        wait "$RP_PID" 2>/dev/null || true
      fi
      rm -rf "$WORK"
    }
    trap cleanup EXIT

    cat > "$CONFIG" <<YAML
    ${constants.mkRedpandaYaml {
      kafkaUnixPath = "SOCK_PATH_PLACEHOLDER";
      kafkaUnixMode = udsMode;
    }}
    YAML
    sed -i "s|DATA_DIR_PLACEHOLDER|$DATA_DIR|g" "$CONFIG"
    sed -i "s|SOCK_PATH_PLACEHOLDER|$SOCK_PATH|g" "$CONFIG"

    bold "========================================="
    bold "  Redpanda UDS Kafka Listener Test"
    bold "========================================="

    # --- Phase 1: Start with dual-listener config ---
    phase_header 1 "Start (TCP + UDS)" ${toString constants.timeouts.startup}
    start_phase=$(time_ms)
    start_redpanda "$CONFIG"
    if wait_for_ready; then
      result_pass "broker ready on TCP admin endpoint" "$(elapsed_ms "$start_phase")"
      record_pass
    else
      result_fail "broker failed to start" "$(elapsed_ms "$start_phase")"
      record_fail
      error "FATAL: cannot continue without running broker"
      exit 1
    fi

    # --- Phase 2: Socket on-disk invariants ---
    phase_header 2 "UDS Socket Probe" 10
    ${udsChecks.mkSocketProbeChecks udsMode}

    # --- Phase 3: Pure-UDS round-trip ---
    phase_header 3 "UDS Produce/Consume" 30
    ${udsChecks.mkUdsRoundTripChecks}

    # --- Phase 4: Cross-transport (mixed-transport deployment) ---
    phase_header 4 "Cross-Transport Round-Trip" 30
    ${udsChecks.mkCrossTransportChecks}

    # --- Phase 5: Graceful shutdown cleanup ---
    phase_header 5 "Shutdown Cleanup" ${toString constants.timeouts.shutdown}
    ${udsChecks.mkShutdownCleanupChecks}

    # --- Phase 6: Stale-socket recovery ---
    phase_header 6 "Stale-Socket Recovery" ${toString constants.timeouts.startup}
    ${udsChecks.mkStaleSocketChecks}

    # --- Summary ---
    ${testLib.summaryBlock}
  '';
}
