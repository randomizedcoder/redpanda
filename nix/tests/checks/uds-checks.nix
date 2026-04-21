# UDS (Unix Domain Socket) checks for the Kafka listener.
#
# Exercises the mixed-transport deployment model (TCP + UDS listeners
# on the same broker) which is the default production shape for K8s
# same-node colocation. Each check captures per-phase timing so the
# test runs cleanly alongside the existing single-node suite.
{ rpkDrv, constants }:

let
  rpk = "${rpkDrv}/bin/rpk";
  tcpBrokers = "--brokers 127.0.0.1:${toString constants.ports.kafka}";
  # SOCK_PATH is a shell variable set by the caller; `unix://$SOCK_PATH`
  # is the broker URI understood by rpk's UDSDialer (pkg/kafka/uds_dialer.go).
  udsBrokers = ''--brokers "unix://$SOCK_PATH"'';
in
{
  # Socket-on-disk sanity: inode exists, is a socket, mode matches config.
  mkSocketProbeChecks = expectedMode: ''
    sock_start=$(time_ms)
    if [[ -S "$SOCK_PATH" ]]; then
      result_pass "UDS socket inode present at $SOCK_PATH" "$(elapsed_ms "$sock_start")"
      record_pass
    else
      result_fail "UDS socket missing at $SOCK_PATH" "$(elapsed_ms "$sock_start")"
      record_fail
    fi

    mode_start=$(time_ms)
    # %04a zero-pads the octal mode to 4 digits so "660" compares equal to
    # the typical "0660" form used in the expectedMode config.
    actual_mode=$(stat -c %04a "$SOCK_PATH" 2>/dev/null || echo "???")
    if [[ "$actual_mode" == "${expectedMode}" ]]; then
      result_pass "UDS socket mode is ${expectedMode}" "$(elapsed_ms "$mode_start")"
      record_pass
    else
      result_fail "UDS socket mode expected ${expectedMode}, got $actual_mode" "$(elapsed_ms "$mode_start")"
      record_fail
    fi

    lock_start=$(time_ms)
    if [[ -f "$SOCK_PATH.lock" ]]; then
      result_pass "UDS lockfile present at $SOCK_PATH.lock" "$(elapsed_ms "$lock_start")"
      record_pass
    else
      result_fail "UDS lockfile missing at $SOCK_PATH.lock" "$(elapsed_ms "$lock_start")"
      record_fail
    fi
  '';

  # Same-transport round-trip over UDS: produce + consume using rpk's
  # unix:// broker URI. Confirms Phase 5 (rpk UDSDialer) routes traffic
  # correctly to an AF_UNIX broker.
  mkUdsRoundTripChecks = ''
    ${rpk} topic create nix-uds-topic ${tcpBrokers} 2>/dev/null || true

    uds_prod_start=$(time_ms)
    if echo "${constants.testMessages.small}" | ${rpk} topic produce nix-uds-topic ${udsBrokers} >/dev/null 2>&1; then
      result_pass "produce via UDS succeeded" "$(elapsed_ms "$uds_prod_start")"
      record_pass
    else
      result_fail "produce via UDS failed" "$(elapsed_ms "$uds_prod_start")"
      record_fail
    fi

    uds_cons_start=$(time_ms)
    UDS_OUT=$(timeout 10 ${rpk} topic consume nix-uds-topic -n 1 -f '%v\n' ${udsBrokers} 2>/dev/null || echo "")
    if echo "$UDS_OUT" | grep -q "${constants.testMessages.small}"; then
      result_pass "consume via UDS round-trip" "$(elapsed_ms "$uds_cons_start")"
      record_pass
    else
      result_fail "consume via UDS got '$UDS_OUT'" "$(elapsed_ms "$uds_cons_start")"
      record_fail
    fi
  '';

  # Cross-transport: produce on one transport, consume on the other.
  # Asserts transport is invisible at the Kafka-protocol layer — the
  # point of having UDS as an additive listener rather than a separate
  # plane.
  mkCrossTransportChecks = ''
    ${rpk} topic create nix-uds-cross-a ${tcpBrokers} 2>/dev/null || true
    ${rpk} topic create nix-uds-cross-b ${tcpBrokers} 2>/dev/null || true

    cross1_start=$(time_ms)
    echo "${constants.testMessages.small}-a" | ${rpk} topic produce nix-uds-cross-a ${tcpBrokers} >/dev/null 2>&1
    CROSS1_OUT=$(timeout 10 ${rpk} topic consume nix-uds-cross-a -n 1 -f '%v\n' ${udsBrokers} 2>/dev/null || echo "")
    if echo "$CROSS1_OUT" | grep -q "${constants.testMessages.small}-a"; then
      result_pass "cross-transport: produce TCP, consume UDS" "$(elapsed_ms "$cross1_start")"
      record_pass
    else
      result_fail "cross-transport TCP->UDS got '$CROSS1_OUT'" "$(elapsed_ms "$cross1_start")"
      record_fail
    fi

    cross2_start=$(time_ms)
    echo "${constants.testMessages.small}-b" | ${rpk} topic produce nix-uds-cross-b ${udsBrokers} >/dev/null 2>&1
    CROSS2_OUT=$(timeout 10 ${rpk} topic consume nix-uds-cross-b -n 1 -f '%v\n' ${tcpBrokers} 2>/dev/null || echo "")
    if echo "$CROSS2_OUT" | grep -q "${constants.testMessages.small}-b"; then
      result_pass "cross-transport: produce UDS, consume TCP" "$(elapsed_ms "$cross2_start")"
      record_pass
    else
      result_fail "cross-transport UDS->TCP got '$CROSS2_OUT'" "$(elapsed_ms "$cross2_start")"
      record_fail
    fi
  '';

  # Graceful shutdown must unlink socket and lockfile — otherwise the
  # next start would either fail (live-socket detection) or rely on
  # stale-socket recovery (which is slower and warns loudly).
  mkShutdownCleanupChecks = ''
    shutdown_start=$(time_ms)
    if graceful_shutdown "$RP_PID"; then
      result_pass "graceful shutdown within timeout" "$(elapsed_ms "$shutdown_start")"
      record_pass
    else
      result_fail "graceful shutdown timed out" "$(elapsed_ms "$shutdown_start")"
      record_fail
    fi
    RP_PID=""

    cleanup_sock_start=$(time_ms)
    if [[ ! -e "$SOCK_PATH" ]]; then
      result_pass "UDS socket unlinked on shutdown" "$(elapsed_ms "$cleanup_sock_start")"
      record_pass
    else
      result_fail "UDS socket still present after shutdown" "$(elapsed_ms "$cleanup_sock_start")"
      record_fail
    fi

    cleanup_lock_start=$(time_ms)
    if [[ ! -e "$SOCK_PATH.lock" ]]; then
      result_pass "UDS lockfile unlinked on shutdown" "$(elapsed_ms "$cleanup_lock_start")"
      record_pass
    else
      result_fail "UDS lockfile still present after shutdown" "$(elapsed_ms "$cleanup_lock_start")"
      record_fail
    fi
  '';

  # Stale-socket recovery: plant a bind-but-no-listen socket inode at
  # the target path, then start Redpanda. The prepare_uds_path() helper
  # should connect()-probe, see ECONNREFUSED, unlink, and continue.
  # We assert the functional outcome (broker up + UDS reachable again)
  # rather than log-grep, which is fragile across Seastar log-format
  # changes.
  mkStaleSocketChecks = ''
        stale_start=$(time_ms)

        # Bind an AF_UNIX socket but never listen — the fd closes when the
        # python process exits so only the inode remains, mimicking a
        # previous broker that crashed without cleanup.
        python3 -c '
    import socket, sys
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(sys.argv[1])
    # intentionally no listen(); exit drops fd but leaves inode.
    ' "$SOCK_PATH"

        if [[ ! -S "$SOCK_PATH" ]]; then
          result_fail "stale socket setup: inode missing" "$(elapsed_ms "$stale_start")"
          record_fail
        else
          start_redpanda "$CONFIG"
          if wait_for_ready; then
            result_pass "broker recovered over stale UDS inode" "$(elapsed_ms "$stale_start")"
            record_pass
          else
            result_fail "broker failed to start over stale UDS inode" "$(elapsed_ms "$stale_start")"
            record_fail
          fi

          uds_reach_start=$(time_ms)
          if ${rpk} cluster info ${udsBrokers} >/dev/null 2>&1; then
            result_pass "rpk reaches broker via UDS after stale recovery" "$(elapsed_ms "$uds_reach_start")"
            record_pass
          else
            result_fail "rpk cannot reach broker via UDS after stale recovery" "$(elapsed_ms "$uds_reach_start")"
            record_fail
          fi
        fi
  '';
}
