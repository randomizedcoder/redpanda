# nix/tests/uds-perf.nix
#
# End-to-end UDS vs TCP produce performance benchmark.
#
# Starts a single-node Redpanda with dual Kafka listeners (TCP + UDS),
# then runs `rpk benchmark produce` through each transport at several
# message sizes and client counts. Prints a comparison table showing
# where UDS gains are largest.
#
# Run with:
#   nix run .#bench-uds-perf           # 30s per cell (~7 min total)
#   nix run .#bench-uds-perf-quick     # 10s per cell (~3 min total)
{
  pkgs,
  redpandaDrv,
  rpkDrv,
  duration ? 30,
  warmup ? 10,
}:

let
  testLib = import ./lib.nix { inherit redpandaDrv rpkDrv; };
  inherit (testLib) constants;
  perfChecks = import ./checks/uds-perf-checks.nix { inherit rpkDrv constants; };

  udsMode = "0660";
in
pkgs.writeShellApplication {
  name = "bench-uds-perf";
  runtimeInputs = with pkgs; [
    coreutils
    gnugrep
    gawk
    curl
    jq
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

    bold "╔═══════════════════════════════════════════╗"
    bold "║  UDS vs TCP Produce Performance Benchmark ║"
    bold "╚═══════════════════════════════════════════╝"
    echo ""
    info "Duration per cell: ${toString duration}s (warmup: ${toString warmup}s)"
    info "Message sizes: 100 B, 1 kB, 10 kB"
    info "Client counts: 1, 10"
    info "Transports: tcp, uds"
    echo ""

    # --- Start broker ---
    phase_header 1 "Start Broker (TCP + UDS)" ${toString constants.timeouts.startup}
    start_phase=$(time_ms)
    start_redpanda "$CONFIG"
    if wait_for_ready; then
      result_pass "broker ready" "$(elapsed_ms "$start_phase")"
      record_pass
    else
      result_fail "broker failed to start" "$(elapsed_ms "$start_phase")"
      record_fail
      error "FATAL: cannot continue without running broker"
      exit 1
    fi

    # Verify UDS socket is up
    if [[ -S "$SOCK_PATH" ]]; then
      result_pass "UDS socket present at $SOCK_PATH"
      record_pass
    else
      result_fail "UDS socket missing — benchmark will fail for UDS transport"
      record_fail
    fi

    # --- Run benchmark matrix ---
    phase_header 2 "Benchmark Matrix" 600

    ${perfChecks.mkBenchHelpers}
    ${perfChecks.mkPerfMatrix { inherit duration warmup; }}

    # --- Shutdown ---
    phase_header 3 "Shutdown" ${toString constants.timeouts.shutdown}
    shutdown_start=$(time_ms)
    if graceful_shutdown "$RP_PID"; then
      result_pass "graceful shutdown" "$(elapsed_ms "$shutdown_start")"
      record_pass
    else
      result_fail "shutdown timed out" "$(elapsed_ms "$shutdown_start")"
      record_fail
    fi
    RP_PID=""

    # --- Summary ---
    ${testLib.summaryBlock}
  '';
}
