# UDS vs TCP produce performance comparison using `rpk benchmark produce`.
#
# Runs rpk benchmark with the same parameters through both TCP and UDS
# listeners on the same broker and prints a comparison table.
#
# SOCK_PATH is a shell variable set by the caller.
{ rpkDrv, constants }:

let
  rpk = "${rpkDrv}/bin/rpk";
  tcpBrokers = "127.0.0.1:${toString constants.ports.kafka}";
in
{
  # Run a single benchmark cell and capture JSON metrics.
  # Args: $1=transport_label, $2=brokers_uri, $3=record_size, $4=clients,
  #       $5=duration, $6=warmup, $7=topic_name
  mkBenchHelpers = ''
    PERF_RESULTS_FILE=$(mktemp)

    run_bench() {
      local transport="$1" brokers="$2" size="$3" clients="$4"
      local duration="$5" warmup="$6" topic="$7"
      local metrics_file; metrics_file=$(mktemp)

      # Create topic via TCP admin (topic creation is not transport-dependent)
      ${rpk} topic create "$topic" --brokers "${tcpBrokers}" \
        --partitions 6 --replicas 1 >/dev/null 2>&1 || true

      info "  Running $transport: size=$size clients=$clients duration=''${duration}s ..."
      local bench_start; bench_start=$(time_ms)

      if ${rpk} -X "brokers=$brokers" benchmark produce \
          --topic "$topic" \
          --partitions 6 --replicas 1 \
          --clients "$clients" \
          --record-size "$size" \
          --warmup "$warmup" \
          --duration "$duration" \
          --metrics-json "$metrics_file" \
          --wait-leadership-balanced=true \
          >"$WORK/rpk-bench-$transport-$size-$clients.log" 2>&1; then

        local req_s mb_s errors
        req_s=$(jq -r '.requests_per_sec' "$metrics_file")
        mb_s=$(jq -r '.mb_per_sec' "$metrics_file")
        errors=$(jq -r '.errors' "$metrics_file")
        local elapsed; elapsed=$(elapsed_ms "$bench_start")

        if [[ "$errors" != "0" ]]; then
          result_fail "$transport size=$size clients=$clients: $errors errors" "$elapsed"
          record_fail
          echo "$transport $size $clients 0 0" >> "$PERF_RESULTS_FILE"
        else
          result_pass "$transport size=$size clients=$clients: $req_s req/s, $mb_s MB/s" "$elapsed"
          record_pass
          echo "$transport $size $clients $req_s $mb_s" >> "$PERF_RESULTS_FILE"
        fi
      else
        result_fail "$transport size=$size clients=$clients: rpk benchmark failed" "$(elapsed_ms "$bench_start")"
        record_fail
        echo "$transport $size $clients 0 0" >> "$PERF_RESULTS_FILE"
      fi

      rm -f "$metrics_file"
    }
  '';

  # Run the full comparison matrix and print results.
  # Parameters: duration (seconds), warmup (seconds)
  mkPerfMatrix = { duration ? 30, warmup ? 10 }: ''
    bench_matrix_start=$(time_ms)

    # Matrix: (record_size, clients)
    for size in 100 1024 10240; do
      for clients in 1 10; do
        run_bench "tcp" "${tcpBrokers}" "$size" "$clients" \
          "${toString duration}" "${toString warmup}" \
          "perf-tcp-''${size}b-''${clients}c"

        run_bench "uds" "unix://$SOCK_PATH" "$size" "$clients" \
          "${toString duration}" "${toString warmup}" \
          "perf-uds-''${size}b-''${clients}c"
      done
    done

    # Print comparison table
    echo ""
    bold "╔═══════════════════════════════════════════════════════════════════════════════════════════════╗"
    bold "║                    UDS vs TCP Produce Benchmark — rpk end-to-end                            ║"
    bold "╠════════╤════════╤══════════════╤══════════════╤══════════╤══════════╤══════════╤═════════════╣"
    bold "║MsgSize │Clients │  TCP req/s   │  UDS req/s   │ req Ratio│ TCP MB/s │ UDS MB/s │  MB Ratio   ║"
    bold "╠════════╪════════╪══════════════╪══════════════╪══════════╪══════════╪══════════╪═════════════╣"

    for size in 100 1024 10240; do
      for clients in 1 10; do
        tcp_line=$(grep "^tcp $size $clients " "$PERF_RESULTS_FILE" || echo "tcp $size $clients 0 0")
        uds_line=$(grep "^uds $size $clients " "$PERF_RESULTS_FILE" || echo "uds $size $clients 0 0")

        tcp_req=$(echo "$tcp_line" | awk '{print $4}')
        tcp_mb=$(echo "$tcp_line" | awk '{print $5}')
        uds_req=$(echo "$uds_line" | awk '{print $4}')
        uds_mb=$(echo "$uds_line" | awk '{print $5}')

        # Format size
        if [[ $size -ge 1024 ]]; then
          fmt_size="$((size / 1024)) kB"
        else
          fmt_size="$size B"
        fi

        # Compute ratios with awk (bash can't do float math)
        req_ratio=$(awk "BEGIN { if ($tcp_req > 0) printf \"%.2f\", $uds_req / $tcp_req; else print \"N/A\" }")
        mb_ratio=$(awk "BEGIN { if ($tcp_mb > 0) printf \"%.2f\", $uds_mb / $tcp_mb; else print \"N/A\" }")

        printf "║%7s │%7s │%13s │%13s │%8sx │%9s │%9s │%10sx  ║\n" \
          "$fmt_size" "$clients" \
          "$(printf '%.0f' "$tcp_req")" "$(printf '%.0f' "$uds_req")" "$req_ratio" \
          "$(printf '%.2f' "$tcp_mb")" "$(printf '%.2f' "$uds_mb")" "$mb_ratio"
      done
    done

    bold "╚════════╧════════╧══════════════╧══════════════╧══════════╧══════════╧══════════╧═════════════╝"
    echo ""
    info "Total benchmark time: $(format_ms "$(elapsed_ms "$bench_matrix_start")")"

    rm -f "$PERF_RESULTS_FILE"
  '';
}
