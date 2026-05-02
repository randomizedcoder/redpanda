# nix/tests/uds-perf.nix
#
# End-to-end UDS vs TCP performance benchmark (produce, consume, rate-limited).
#
# Starts a single-node Redpanda with dual Kafka listeners (TCP + UDS),
# then runs rpk benchmark through each transport. Three phases:
#   1. Produce — 3 sizes × 2 client counts × 2 transports = 12 cells
#   2. Consume — reads from topics populated in phase 1 = 12 cells
#   3. Rate-limited produce — 2 sizes × 2 rates × 2 transports = 8 cells
#
# Prints comparison tables with throughput, latency, and CPU metrics.
#
# Run with:
#   nix run .#bench-uds-perf           # 30s per cell (~21 min total)
#   nix run .#bench-uds-perf-quick     # 10s per cell (~8 min total)
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

    bold "╔═══════════════════════════════════════════════════════╗"
    bold "║  UDS vs TCP Performance Benchmark (produce/consume) ║"
    bold "╚═══════════════════════════════════════════════════════╝"
    echo ""
    info "Duration per cell: ${toString duration}s (warmup: ${toString warmup}s)"
    info "Phase 1+2: Produce & consume — sizes: 100 B, 1 kB, 10 kB × clients: 1, 10, 50 (50 capped at ≤1kB)"
    info "Phase 3: Rated    — sizes: 1 kB, 10 kB × rates: 10, 50, 100 MB/s"
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
    phase_header 2 "Benchmark Matrix" 1200

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
