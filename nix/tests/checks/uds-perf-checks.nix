# UDS vs TCP performance comparison using rpk benchmark (produce, consume,
# rate-limited produce).
#
# Runs rpk benchmark with the same parameters through both TCP and UDS
# listeners on the same broker and prints comparison tables.
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

      local rpk_log="$WORK/rpk-bench-$transport-$size-$clients.log"
      local rpk_rc=0
      ${rpk} -X "brokers=$brokers" benchmark produce \
          --topic "$topic" \
          --use-existing-topic \
          --partitions 6 --replicas 1 \
          --clients "$clients" \
          --record-size "$size" \
          --warmup "$warmup" \
          --duration "$duration" \
          --metrics-json "$metrics_file" \
          --wait-leadership-balanced=true \
          >"$rpk_log" 2>&1 || rpk_rc=$?
      if [ "$rpk_rc" -eq 0 ]; then

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
        result_fail "$transport size=$size clients=$clients: rpk benchmark failed (rc=$rpk_rc)" "$(elapsed_ms "$bench_start")"
        echo "  rpk log ($rpk_log):" >&2
        cat "$rpk_log" >&2 || true
        echo "  rpk binary: ${rpk}" >&2
        ${rpk} benchmark --help >&2 2>&1 || true
        record_fail
        echo "$transport $size $clients 0 0" >> "$PERF_RESULTS_FILE"
      fi

      rm -f "$metrics_file"
    }

    # Run a consume benchmark cell.
    # Args: $1=transport, $2=brokers, $3=clients, $4=duration, $5=warmup, $6=topic
    run_bench_consume() {
      local transport="$1" brokers="$2" clients="$3"
      local duration="$4" warmup="$5" topic="$6"
      local metrics_file; metrics_file=$(mktemp)

      info "  Consuming $transport: clients=$clients duration=''${duration}s ..."
      local bench_start; bench_start=$(time_ms)

      if ${rpk} -X "brokers=$brokers" benchmark consume \
          --topic "$topic" \
          --use-existing-topic \
          --clients "$clients" \
          --warmup "$warmup" \
          --duration "$duration" \
          --metrics-json "$metrics_file" \
          --wait-leadership-balanced=false \
          >"$WORK/rpk-bench-consume-$transport-$clients.log" 2>&1; then

        local req_s mb_s errors p99
        req_s=$(jq -r '.requests_per_sec' "$metrics_file")
        mb_s=$(jq -r '.mb_per_sec' "$metrics_file")
        errors=$(jq -r '.errors' "$metrics_file")
        p99=$(jq -r '.p99_latency_us' "$metrics_file")
        local elapsed; elapsed=$(elapsed_ms "$bench_start")

        if [[ "$errors" != "0" ]]; then
          result_fail "consume $transport clients=$clients: $errors errors" "$elapsed"
          record_fail
          echo "$transport $clients 0 0 0" >> "$CONSUME_RESULTS_FILE"
        else
          result_pass "consume $transport clients=$clients: $req_s req/s, $mb_s MB/s, p99=$p99 us" "$elapsed"
          record_pass
          echo "$transport $clients $req_s $mb_s $p99" >> "$CONSUME_RESULTS_FILE"
        fi
      else
        result_fail "consume $transport clients=$clients: rpk benchmark failed" "$(elapsed_ms "$bench_start")"
        echo "  rpk output:" >&2
        cat "$WORK/rpk-bench-consume-$transport-$clients.log" >&2 || true
        record_fail
        echo "$transport $clients 0 0 0" >> "$CONSUME_RESULTS_FILE"
      fi

      rm -f "$metrics_file"
    }

    # Run a rate-limited produce benchmark cell.
    # Args: $1=transport, $2=brokers, $3=record_size, $4=rate_mbps,
    #       $5=duration, $6=warmup, $7=topic
    run_bench_rated() {
      local transport="$1" brokers="$2" size="$3" rate="$4"
      local duration="$5" warmup="$6" topic="$7"
      local metrics_file; metrics_file=$(mktemp)

      # Create topic via TCP admin
      ${rpk} topic create "$topic" --brokers "${tcpBrokers}" \
        --partitions 6 --replicas 1 >/dev/null 2>&1 || true

      info "  Rated $transport: size=$size rate=$rate MB/s duration=''${duration}s ..."
      local bench_start; bench_start=$(time_ms)

      if ${rpk} -X "brokers=$brokers" benchmark produce \
          --topic "$topic" \
          --use-existing-topic \
          --partitions 6 --replicas 1 \
          --clients 10 \
          --record-size "$size" \
          --target-rate "$rate" \
          --warmup "$warmup" \
          --duration "$duration" \
          --metrics-json "$metrics_file" \
          --wait-leadership-balanced=true \
          >"$WORK/rpk-bench-rated-$transport-$size-$rate.log" 2>&1; then

        local req_s mb_s errors p99 cpu_user cpu_sys
        req_s=$(jq -r '.requests_per_sec' "$metrics_file")
        mb_s=$(jq -r '.mb_per_sec' "$metrics_file")
        errors=$(jq -r '.errors' "$metrics_file")
        p99=$(jq -r '.p99_latency_us' "$metrics_file")
        cpu_user=$(jq -r '.cpu_user_sec' "$metrics_file")
        cpu_sys=$(jq -r '.cpu_sys_sec' "$metrics_file")
        local elapsed; elapsed=$(elapsed_ms "$bench_start")

        if [[ "$errors" != "0" ]]; then
          result_fail "rated $transport size=$size rate=$rate: $errors errors" "$elapsed"
          record_fail
          echo "$transport $size $rate 0 0 0 0 0" >> "$RATED_RESULTS_FILE"
        else
          result_pass "rated $transport size=$size rate=$rate: $mb_s MB/s, p99=$p99 us" "$elapsed"
          record_pass
          echo "$transport $size $rate $req_s $mb_s $p99 $cpu_user $cpu_sys" >> "$RATED_RESULTS_FILE"
        fi
      else
        result_fail "rated $transport size=$size rate=$rate: rpk benchmark failed" "$(elapsed_ms "$bench_start")"
        echo "  rpk output:" >&2
        cat "$WORK/rpk-bench-rated-$transport-$size-$rate.log" >&2 || true
        record_fail
        echo "$transport $size $rate 0 0 0 0 0" >> "$RATED_RESULTS_FILE"
      fi

      rm -f "$metrics_file"
    }
  '';

  # Run the full comparison matrix and print results.
  # Parameters: duration (seconds), warmup (seconds)
  mkPerfMatrix = { duration ? 30, warmup ? 10 }: ''
    bench_matrix_start=$(time_ms)
    CONSUME_RESULTS_FILE=$(mktemp)
    RATED_RESULTS_FILE=$(mktemp)

    # ── Phase 1+2: Produce then consume, delete after each pair ──
    # Async produce generates huge data volumes (100s of MB/s). We must
    # delete topics between pairs to avoid exhausting /tmp disk.
    info "Phase 1+2: Produce & consume benchmark"
    for size in 100 1024 10240; do
      # 50 clients with 10 kB records overwhelms a single-node broker;
      # cap concurrency for larger messages.
      max_clients=50
      if [[ $size -ge 10240 ]]; then max_clients=10; fi

      for clients in 1 10 50; do
        if [[ $clients -gt $max_clients ]]; then continue; fi

        # Produce TCP + UDS
        run_bench "tcp" "${tcpBrokers}" "$size" "$clients" \
          "${toString duration}" "${toString warmup}" \
          "perf-tcp-''${size}b-''${clients}c"

        run_bench "uds" "unix://$SOCK_PATH" "$size" "$clients" \
          "${toString duration}" "${toString warmup}" \
          "perf-uds-''${size}b-''${clients}c"

        # Consume from both topics (only with low client counts to keep it short)
        if [[ $clients -le 10 ]]; then
          run_bench_consume "tcp" "${tcpBrokers}" "$clients" \
            "${toString duration}" "0" \
            "perf-tcp-''${size}b-''${clients}c"

          run_bench_consume "uds" "unix://$SOCK_PATH" "$clients" \
            "${toString duration}" "0" \
            "perf-uds-''${size}b-''${clients}c"
        fi

        # Delete topics to reclaim disk
        ${rpk} topic delete "perf-tcp-''${size}b-''${clients}c" \
          --brokers "${tcpBrokers}" >/dev/null 2>&1 || true
        ${rpk} topic delete "perf-uds-''${size}b-''${clients}c" \
          --brokers "${tcpBrokers}" >/dev/null 2>&1 || true
      done
    done

    # ── Phase 3: Rate-limited produce ──
    info "Phase 3/3: Rate-limited produce benchmark"
    for size in 1024 10240; do
      for rate in 10 50 100; do
        run_bench_rated "tcp" "${tcpBrokers}" "$size" "$rate" \
          "${toString duration}" "${toString warmup}" \
          "perf-rated-tcp-''${size}b-''${rate}mbps"

        run_bench_rated "uds" "unix://$SOCK_PATH" "$size" "$rate" \
          "${toString duration}" "${toString warmup}" \
          "perf-rated-uds-''${size}b-''${rate}mbps"
      done
    done

    # ── Table 1: Produce ──
    echo ""
    bold "╔═══════════════════════════════════════════════════════════════════════════════════════════════╗"
    bold "║                    UDS vs TCP Produce Benchmark — rpk end-to-end                            ║"
    bold "╠════════╤════════╤══════════════╤══════════════╤══════════╤══════════╤══════════╤═════════════╣"
    bold "║MsgSize │Clients │  TCP req/s   │  UDS req/s   │ req Ratio│ TCP MB/s │ UDS MB/s │  MB Ratio   ║"
    bold "╠════════╪════════╪══════════════╪══════════════╪══════════╪══════════╪══════════╪═════════════╣"

    for size in 100 1024 10240; do
      max_clients=50
      if [[ $size -ge 10240 ]]; then max_clients=10; fi
      for clients in 1 10 50; do
        if [[ $clients -gt $max_clients ]]; then continue; fi
        tcp_line=$(grep "^tcp $size $clients " "$PERF_RESULTS_FILE" || echo "tcp $size $clients 0 0")
        uds_line=$(grep "^uds $size $clients " "$PERF_RESULTS_FILE" || echo "uds $size $clients 0 0")

        tcp_req=$(echo "$tcp_line" | awk '{print $4}')
        tcp_mb=$(echo "$tcp_line" | awk '{print $5}')
        uds_req=$(echo "$uds_line" | awk '{print $4}')
        uds_mb=$(echo "$uds_line" | awk '{print $5}')

        if [[ $size -ge 1024 ]]; then
          fmt_size="$((size / 1024)) kB"
        else
          fmt_size="$size B"
        fi

        req_ratio=$(awk "BEGIN { if ($tcp_req > 0) printf \"%.2f\", $uds_req / $tcp_req; else print \"N/A\" }")
        mb_ratio=$(awk "BEGIN { if ($tcp_mb > 0) printf \"%.2f\", $uds_mb / $tcp_mb; else print \"N/A\" }")

        printf "║%7s │%7s │%13s │%13s │%8sx │%9s │%9s │%10sx  ║\n" \
          "$fmt_size" "$clients" \
          "$(printf '%.0f' "$tcp_req")" "$(printf '%.0f' "$uds_req")" "$req_ratio" \
          "$(printf '%.2f' "$tcp_mb")" "$(printf '%.2f' "$uds_mb")" "$mb_ratio"
      done
    done

    bold "╚════════╧════════╧══════════════╧══════════════╧══════════╧══════════╧══════════╧═════════════╝"

    # ── Table 2: Consume ──
    echo ""
    bold "╔════════════════════════════════════════════════════════════════════════════════════════════════════╗"
    bold "║                    UDS vs TCP Consume Benchmark — rpk end-to-end                                 ║"
    bold "╠════════╤══════════════╤══════════════╤══════════╤══════════╤══════════╤══════════════╤═════════════╣"
    bold "║Clients │  TCP req/s   │  UDS req/s   │ req Ratio│ TCP MB/s │ UDS MB/s │ UDS p99 (us) │  MB Ratio   ║"
    bold "╠════════╪══════════════╪══════════════╪══════════╪══════════╪══════════╪══════════════╪═════════════╣"

    for clients in 1 10; do
      tcp_line=$(grep "^tcp $clients " "$CONSUME_RESULTS_FILE" || echo "tcp $clients 0 0 0")
      uds_line=$(grep "^uds $clients " "$CONSUME_RESULTS_FILE" || echo "uds $clients 0 0 0")

      tcp_req=$(echo "$tcp_line" | awk '{print $3}')
      tcp_mb=$(echo "$tcp_line" | awk '{print $4}')
      uds_req=$(echo "$uds_line" | awk '{print $3}')
      uds_mb=$(echo "$uds_line" | awk '{print $4}')
      uds_p99=$(echo "$uds_line" | awk '{print $5}')

      req_ratio=$(awk "BEGIN { if ($tcp_req > 0) printf \"%.2f\", $uds_req / $tcp_req; else print \"N/A\" }")
      mb_ratio=$(awk "BEGIN { if ($tcp_mb > 0) printf \"%.2f\", $uds_mb / $tcp_mb; else print \"N/A\" }")

      printf "║%7s │%13s │%13s │%8sx │%9s │%9s │%13s │%10sx  ║\n" \
        "$clients" \
        "$(printf '%.0f' "$tcp_req")" "$(printf '%.0f' "$uds_req")" "$req_ratio" \
        "$(printf '%.2f' "$tcp_mb")" "$(printf '%.2f' "$uds_mb")" \
        "$(printf '%.0f' "$uds_p99")" "$mb_ratio"
    done

    bold "╚════════╧══════════════╧══════════════╧══════════╧══════════╧══════════╧══════════════╧═════════════╝"

    # ── Table 3: Rate-limited produce ──
    echo ""
    bold "╔══════════════════════════════════════════════════════════════════════════════════════════════════════════╗"
    bold "║                    UDS vs TCP Rate-Limited Produce — rpk end-to-end                                    ║"
    bold "╠════════╤═══════════╤══════════╤══════════╤════════════╤════════════╤══════════════╤══════════════════════╣"
    bold "║MsgSize │Target MB/s│ TCP MB/s │ UDS MB/s │ TCP p99(us)│ UDS p99(us)│  p99 Ratio   │ CPU(user+sys) Ratio ║"
    bold "╠════════╪═══════════╪══════════╪══════════╪════════════╪════════════╪══════════════╪══════════════════════╣"

    for size in 1024 10240; do
      for rate in 10 50 100; do
        tcp_line=$(grep "^tcp $size $rate " "$RATED_RESULTS_FILE" || echo "tcp $size $rate 0 0 0 0 0")
        uds_line=$(grep "^uds $size $rate " "$RATED_RESULTS_FILE" || echo "uds $size $rate 0 0 0 0 0")

        tcp_mb=$(echo "$tcp_line" | awk '{print $5}')
        uds_mb=$(echo "$uds_line" | awk '{print $5}')
        tcp_p99=$(echo "$tcp_line" | awk '{print $6}')
        uds_p99=$(echo "$uds_line" | awk '{print $6}')
        tcp_cpu_u=$(echo "$tcp_line" | awk '{print $7}')
        tcp_cpu_s=$(echo "$tcp_line" | awk '{print $8}')
        uds_cpu_u=$(echo "$uds_line" | awk '{print $7}')
        uds_cpu_s=$(echo "$uds_line" | awk '{print $8}')

        if [[ $size -ge 1024 ]]; then
          fmt_size="$((size / 1024)) kB"
        else
          fmt_size="$size B"
        fi

        p99_ratio=$(awk "BEGIN { if ($tcp_p99 > 0) printf \"%.2f\", $uds_p99 / $tcp_p99; else print \"N/A\" }")
        tcp_cpu_total=$(awk "BEGIN { printf \"%.2f\", $tcp_cpu_u + $tcp_cpu_s }")
        uds_cpu_total=$(awk "BEGIN { printf \"%.2f\", $uds_cpu_u + $uds_cpu_s }")
        cpu_ratio=$(awk "BEGIN { if ($tcp_cpu_total > 0) printf \"%.2f\", $uds_cpu_total / $tcp_cpu_total; else print \"N/A\" }")

        printf "║%7s │%10s │%9s │%9s │%11s │%11s │%12sx │%18sx  ║\n" \
          "$fmt_size" "$rate" \
          "$(printf '%.2f' "$tcp_mb")" "$(printf '%.2f' "$uds_mb")" \
          "$(printf '%.0f' "$tcp_p99")" "$(printf '%.0f' "$uds_p99")" "$p99_ratio" "$cpu_ratio"
      done
    done

    bold "╚════════╧═══════════╧══════════╧══════════╧════════════╧════════════╧══════════════╧══════════════════════╝"
    echo ""
    info "Total benchmark time: $(format_ms "$(elapsed_ms "$bench_matrix_start")")"

    rm -f "$PERF_RESULTS_FILE" "$CONSUME_RESULTS_FILE" "$RATED_RESULTS_FILE"
  '';
}
