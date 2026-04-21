{
  pkgs,
  mkApp,
  redpandaDrv ? null,
  rpkDrv ? null,
}:

let
  inherit (pkgs) lib;

  bazelCacheDir = "/var/cache/bazel-nix";

  mkClear =
    {
      clearNix ? false,
      clearBazel ? false,
    }:
    lib.concatStrings [
      (lib.optionalString clearNix ''
        date -u +%Y-%m-%dT%H:%M:%S.%NZ > nix/entropy
        echo "[bench] Wrote entropy file (Nix cache invalidated)"
      '')
      (lib.optionalString clearBazel ''
        sudo rm -rf ${bazelCacheDir}/*
        echo "[bench] Cleared persistent Bazel cache at ${bazelCacheDir}"
      '')
    ];

  mkBench =
    {
      name,
      target ? "redpanda-cached",
      clearNix ? false,
      clearBazel ? false,
      repeat ? 1,
    }:
    mkApp (
      pkgs.writeShellApplication {
        name = "redpanda-bench-${name}";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.nix
        ];
        text = ''
          for i in $(seq 1 ${toString repeat}); do
            echo "=== Run $i/${toString repeat}: ${name} ==="
            ${mkClear { inherit clearNix clearBazel; }}
            echo "[bench] Building..."
            time nix build .#${target} --print-build-logs
            echo "[bench] Done"
            echo ""
          done
        '';
      }
    );

  mkClearOnly =
    {
      name,
      clearNix ? false,
      clearBazel ? false,
    }:
    mkApp (
      pkgs.writeShellApplication {
        name = "redpanda-${name}";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.nix
        ];
        text = mkClear { inherit clearNix clearBazel; };
      }
    );

in
{
  # Clear-only targets (no build)
  clear-nix = mkClearOnly {
    name = "clear-nix";
    clearNix = true;
  };

  clear-bazel = mkClearOnly {
    name = "clear-bazel";
    clearBazel = true;
  };

  clear-all = mkClearOnly {
    name = "clear-all";
    clearNix = true;
    clearBazel = true;
  };

  # Single-run benchmarks (use redpanda-cached for persistent Bazel cache)
  bench-warm = mkBench {
    name = "warm";
  };

  bench-cold-nix = mkBench {
    name = "cold-nix";
    clearNix = true;
  };

  bench-cold-bazel = mkBench {
    name = "cold-bazel";
    clearBazel = true;
  };

  bench-cold-all = mkBench {
    name = "cold-all";
    clearNix = true;
    clearBazel = true;
  };

  # 3x repeated benchmarks
  bench-3x-warm = mkBench {
    name = "3x-warm";
    repeat = 3;
  };

  bench-3x-cold-nix = mkBench {
    name = "3x-cold-nix";
    clearNix = true;
    repeat = 3;
  };

  # Runtime benchmark: UDS vs TCP produce/consume.
  #
  # Brings up a Redpanda broker with a dual-transport Kafka listener
  # (TCP + AF_UNIX) and drives fixed-byte produce/consume workloads
  # through rpk over each transport, emitting a one-line JSON record
  # per (transport, phase) pair that captures elapsed time, bytes
  # throughput, and (if available on the host) sendmsg/recvmsg syscall
  # counts via `perf stat`.
  #
  # This is intentionally coarse — the numbers are order-of-magnitude
  # comparisons, not production-grade benchmarks. Run with `--smp=1`
  # to keep the broker on a single reactor shard (AF_UNIX does not
  # shard-balance the way SO_REUSEPORT-based TCP does).
  bench-uds-vs-tcp = mkApp (
    pkgs.writeShellApplication {
      name = "redpanda-bench-uds-vs-tcp";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.gnused
        pkgs.jq
        pkgs.curl
        pkgs.perf
      ]
      ++ lib.optional (redpandaDrv != null) redpandaDrv
      ++ lib.optional (rpkDrv != null) rpkDrv;
      text = ''
        set -euo pipefail
        ${lib.optionalString (redpandaDrv == null || rpkDrv == null) ''
          echo "bench-uds-vs-tcp requires both redpandaDrv and rpkDrv — rebuild with a populated flake." >&2
          exit 1
        ''}

        DURATION="''${DURATION:-10}"   # seconds per phase
        PAYLOAD="''${PAYLOAD:-1024}"   # bytes per record
        RECORDS="''${RECORDS:-10000}"  # records per phase

        WORK=$(mktemp -d)
        DATA_DIR="$WORK/data"
        CONFIG="$WORK/redpanda.yaml"
        SOCK_PATH="$WORK/rp.sock"
        LOG="$WORK/redpanda.log"
        REPORT="$WORK/report.json"
        mkdir -p "$DATA_DIR"

        cleanup() {
          if [[ -n "''${RP_PID:-}" ]]; then
            kill -TERM "$RP_PID" 2>/dev/null || true
            wait "$RP_PID" 2>/dev/null || true
          fi
          rm -rf "$WORK"
        }
        trap cleanup EXIT

        # Minimal developer-mode config with a dual-transport Kafka listener.
        cat > "$CONFIG" <<YAML
        redpanda:
          data_directory: $DATA_DIR
          developer_mode: true
          node_id: 0
          rpc_server:
            address: 127.0.0.1
            port: 33145
          kafka_api:
            - address: 127.0.0.1
              port: 9092
              name: tcp
            - unix_path: $SOCK_PATH
              unix_socket_mode: "0660"
              name: uds
          admin:
            - address: 127.0.0.1
              port: 9644
          seed_servers: []
        YAML

        redpanda --redpanda-cfg "$CONFIG" --smp 1 --memory 1G --reserve-memory 0M \
          >"$LOG" 2>&1 &
        RP_PID=$!

        echo "[bench] waiting for broker to become healthy..."
        for _ in $(seq 1 60); do
          if curl -sf http://127.0.0.1:9644/v1/cluster/health_overview >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done

        rpk topic create bench-tcp --brokers 127.0.0.1:9092 >/dev/null || true
        rpk topic create bench-uds --brokers 127.0.0.1:9092 >/dev/null || true

        # Generate a deterministic payload of $PAYLOAD bytes per record.
        PAYLOAD_FILE="$WORK/payload"
        head -c "$PAYLOAD" /dev/urandom > "$PAYLOAD_FILE"

        # Can we run perf? (requires kernel.perf_event_paranoid <= 2 and
        # the `syscalls:*` tracepoints.)
        PERF_OK=0
        if perf stat -e syscalls:sys_enter_sendmsg true 2>/dev/null; then
          PERF_OK=1
        fi

        run_phase() {
          local name="$1" brokers="$2" topic="$3"
          local start_ns end_ns elapsed_ns bytes
          local sendmsg="null" recvmsg="null"
          local perf_out="$WORK/perf-$name.txt"

          bytes=$((PAYLOAD * RECORDS))

          if [[ $PERF_OK -eq 1 ]]; then
            start_ns=$(date +%s%N)
            perf stat -e syscalls:sys_enter_sendmsg,syscalls:sys_enter_recvmsg \
              -o "$perf_out" --no-big-num -- \
              bash -c "for _ in \$(seq 1 $RECORDS); do cat '$PAYLOAD_FILE'; echo; done | rpk topic produce '$topic' --brokers '$brokers' >/dev/null 2>&1"
            end_ns=$(date +%s%N)
            sendmsg=$(sed -n 's/^ *\([0-9][0-9]*\) *syscalls:sys_enter_sendmsg.*/\1/p' "$perf_out" | head -1)
            recvmsg=$(sed -n 's/^ *\([0-9][0-9]*\) *syscalls:sys_enter_recvmsg.*/\1/p' "$perf_out" | head -1)
            sendmsg="''${sendmsg:-null}"
            recvmsg="''${recvmsg:-null}"
          else
            start_ns=$(date +%s%N)
            for _ in $(seq 1 "$RECORDS"); do cat "$PAYLOAD_FILE"; echo; done \
              | rpk topic produce "$topic" --brokers "$brokers" >/dev/null 2>&1
            end_ns=$(date +%s%N)
          fi

          elapsed_ns=$((end_ns - start_ns))

          jq -n \
            --arg transport "$name" \
            --argjson elapsed_ns "$elapsed_ns" \
            --argjson bytes "$bytes" \
            --argjson records "$RECORDS" \
            --argjson payload "$PAYLOAD" \
            --argjson sendmsg "$sendmsg" \
            --argjson recvmsg "$recvmsg" \
            '{
               transport: $transport,
               elapsed_ms: ($elapsed_ns / 1000000 | floor),
               bytes: $bytes,
               records: $records,
               payload_bytes: $payload,
               throughput_MiBps: (($bytes / 1048576) / ($elapsed_ns / 1e9)),
               sendmsg_syscalls: $sendmsg,
               recvmsg_syscalls: $recvmsg
             }'
        }

        echo "[bench] TCP phase..."
        TCP_JSON=$(run_phase tcp "127.0.0.1:9092" bench-tcp)
        echo "$TCP_JSON" | tee -a "$REPORT"

        echo "[bench] UDS phase..."
        UDS_JSON=$(run_phase uds "unix://$SOCK_PATH" bench-uds)
        echo "$UDS_JSON" | tee -a "$REPORT"

        echo ""
        echo "========== UDS vs TCP summary =========="
        jq -n --argjson tcp "$TCP_JSON" --argjson uds "$UDS_JSON" '{
          tcp: $tcp,
          uds: $uds,
          throughput_ratio_uds_over_tcp: ($uds.throughput_MiBps / $tcp.throughput_MiBps)
        }'
      '';
    }
  );

  # Backpressure + burst bench.
  #
  # Steady-state throughput benches hide the behavior users actually
  # feel when senders outrun receivers. This bench intentionally creates
  # that imbalance and samples the system as it reacts. Two scenarios:
  #
  #   slow-consumer : producer runs full-rate, consumer is rate-limited
  #                   via a sleep-paced read loop so it falls behind.
  #                   We sample topic high-watermark + consumer offset
  #                   + broker RSS every 100 ms. Reports peak queue
  #                   depth, latency drift during backpressure, and
  #                   recovery time after the producer stops.
  #
  #   burst         : producer emits in 10 ms bursts every 100 ms
  #                   (90% idle) so the transport sees periodic
  #                   wake-storms. Service meshes handle this very
  #                   differently from local IPC.
  #
  # Each scenario runs over TCP and UDS on the same broker. Emits one
  # JSON record per (scenario, transport) — post-processing picks peak
  # and recovery stats out for the RFC.
  bench-backpressure = mkApp (
    pkgs.writeShellApplication {
      name = "redpanda-bench-backpressure";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.gnused
        pkgs.gawk
        pkgs.jq
        pkgs.curl
        pkgs.procps
      ]
      ++ lib.optional (redpandaDrv != null) redpandaDrv
      ++ lib.optional (rpkDrv != null) rpkDrv;
      text = ''
        set -euo pipefail
        ${lib.optionalString (redpandaDrv == null || rpkDrv == null) ''
          echo "bench-backpressure requires both redpandaDrv and rpkDrv." >&2
          exit 1
        ''}

        DURATION="''${DURATION:-30}"     # seconds producer runs for
        PAYLOAD="''${PAYLOAD:-1024}"     # bytes per record
        PRODUCER_RATE="''${PRODUCER_RATE:-20000}"  # records/s target
        # Consumer's sustainable rate is lower by this fraction; the
        # difference is the backpressure the test is actually exercising.
        CONSUMER_SLOWDOWN="''${CONSUMER_SLOWDOWN:-4}"

        WORK=$(mktemp -d)
        DATA_DIR="$WORK/data"
        CONFIG="$WORK/redpanda.yaml"
        SOCK_PATH="$WORK/rp.sock"
        LOG="$WORK/redpanda.log"
        REPORT="$WORK/backpressure.jsonl"
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
        redpanda:
          data_directory: $DATA_DIR
          developer_mode: true
          node_id: 0
          rpc_server:
            address: 127.0.0.1
            port: 33145
          kafka_api:
            - address: 127.0.0.1
              port: 9092
              name: tcp
            - unix_path: $SOCK_PATH
              unix_socket_mode: "0660"
              name: uds
          admin:
            - address: 127.0.0.1
              port: 9644
          seed_servers: []
        YAML

        redpanda --redpanda-cfg "$CONFIG" --smp 1 --memory 1G --reserve-memory 0M \
          >"$LOG" 2>&1 &
        RP_PID=$!

        echo "[bench] waiting for broker..."
        for _ in $(seq 1 60); do
          if curl -sf http://127.0.0.1:9644/v1/cluster/health_overview >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done

        PAYLOAD_FILE="$WORK/payload"
        head -c "$PAYLOAD" /dev/urandom > "$PAYLOAD_FILE"

        # Sampler: records high_watermark, committed offset, broker RSS
        # at 100 ms cadence while the scenario runs. Writes one JSON
        # object per sample to $1.
        sample_loop() {
          local out="$1" topic="$2"
          while true; do
            local ts hw rss
            ts=$(date +%s%N)
            # hwm via admin API (avoids spinning up rpk per sample)
            hw=$(curl -sf "http://127.0.0.1:9644/v1/partitions/kafka/$topic/0" \
                   2>/dev/null | jq -r '.high_watermark // 0' 2>/dev/null || echo 0)
            rss=$(ps -o rss= -p "$RP_PID" 2>/dev/null | awk '{print $1}')
            jq -n --argjson ts "$ts" --argjson hw "$hw" --argjson rss "''${rss:-0}" \
              '{ts_ns: $ts, high_watermark: $hw, broker_rss_kb: $rss}'
            sleep 0.1
          done
        }

        run_slow_consumer() {
          local transport="$1" brokers="$2" topic="$3"
          local sample_out="$WORK/samples-$transport-slow.jsonl"
          local scenario_start
          scenario_start=$(date +%s%N)

          rpk topic create "$topic" --brokers 127.0.0.1:9092 >/dev/null 2>&1 || true

          sample_loop "$sample_out" "$topic" > "$sample_out" &
          local SAMPLER=$!

          # Rate-limited producer: $PRODUCER_RATE records/s for $DURATION s.
          (for _ in $(seq 1 $((PRODUCER_RATE * DURATION))); do
            cat "$PAYLOAD_FILE"; echo
          done | rpk topic produce "$topic" --brokers "$brokers" \
                    --rate "$PRODUCER_RATE" >/dev/null 2>&1) &
          local PROD=$!

          # Slow consumer: sleeps 1/CONSUMER_SLOWDOWN of the producer
          # period between fetches. rpk's own consume stays greedy — the
          # backpressure surfaces at the offset-commit cadence, which is
          # what the RFC wants to measure.
          (rpk topic consume "$topic" --brokers "$brokers" \
                 -o start -n $((PRODUCER_RATE * DURATION / CONSUMER_SLOWDOWN)) \
                 >/dev/null 2>&1) &
          local CONS=$!

          wait $PROD
          local producer_done_ns
          producer_done_ns=$(date +%s%N)

          # Let the consumer drain; cap wait at 4x DURATION.
          local drain_deadline=$((producer_done_ns + DURATION * 4 * 1000000000))
          while (( $(date +%s%N) < drain_deadline )); do
            local hw
            hw=$(curl -sf "http://127.0.0.1:9644/v1/partitions/kafka/$topic/0" \
                   2>/dev/null | jq -r '.high_watermark // 0' 2>/dev/null || echo 0)
            # Recovery complete when hwm stops growing for 1 full second.
            sleep 0.5
            local hw2
            hw2=$(curl -sf "http://127.0.0.1:9644/v1/partitions/kafka/$topic/0" \
                    2>/dev/null | jq -r '.high_watermark // 0' 2>/dev/null || echo 0)
            if [[ "$hw" == "$hw2" ]]; then
              break
            fi
          done
          local recovered_ns
          recovered_ns=$(date +%s%N)

          kill $SAMPLER 2>/dev/null || true
          kill $CONS 2>/dev/null || true
          wait 2>/dev/null || true

          # Summarize: peak queue depth (hw - last sample's consumer
          # offset is approximated by the max hw growth over any 1 s
          # window; lag samples are kept raw in $sample_out for
          # post-analysis).
          local peak_hw rss_peak
          peak_hw=$(jq -s 'map(.high_watermark) | max' "$sample_out")
          rss_peak=$(jq -s 'map(.broker_rss_kb) | max' "$sample_out")

          jq -n \
            --arg scenario slow-consumer \
            --arg transport "$transport" \
            --argjson duration_s "$DURATION" \
            --argjson producer_rate "$PRODUCER_RATE" \
            --argjson slowdown "$CONSUMER_SLOWDOWN" \
            --argjson producer_done_ns "$producer_done_ns" \
            --argjson scenario_start_ns "$scenario_start" \
            --argjson recovered_ns "$recovered_ns" \
            --argjson peak_hw "$peak_hw" \
            --argjson rss_peak "$rss_peak" \
            '{
               scenario: $scenario,
               transport: $transport,
               producer_rate: $producer_rate,
               consumer_slowdown_factor: $slowdown,
               producer_elapsed_ms: (($producer_done_ns - $scenario_start_ns) / 1000000 | floor),
               recovery_ms: (($recovered_ns - $producer_done_ns) / 1000000 | floor),
               peak_high_watermark: $peak_hw,
               broker_rss_kb_peak: $rss_peak
             }'
        }

        run_burst() {
          local transport="$1" brokers="$2" topic="$3"
          local scenario_start
          scenario_start=$(date +%s%N)

          rpk topic create "$topic" --brokers 127.0.0.1:9092 >/dev/null 2>&1 || true

          # 10 ms bursts of BURST_BATCH records every 100 ms for
          # DURATION seconds. 90% idle means the transport handles a
          # wake-pattern, not steady flow.
          local BURST_BATCH=$((PRODUCER_RATE / 100))
          local cycles=$((DURATION * 10))
          local burst_start_ns burst_end_ns total_latency_ns=0
          for _ in $(seq 1 $cycles); do
            burst_start_ns=$(date +%s%N)
            (for _ in $(seq 1 "$BURST_BATCH"); do
              cat "$PAYLOAD_FILE"; echo
            done | rpk topic produce "$topic" --brokers "$brokers" \
                      >/dev/null 2>&1) || true
            burst_end_ns=$(date +%s%N)
            total_latency_ns=$((total_latency_ns + burst_end_ns - burst_start_ns))
            sleep 0.09
          done

          local avg_burst_us=$((total_latency_ns / cycles / 1000))

          jq -n \
            --arg scenario burst \
            --arg transport "$transport" \
            --argjson cycles "$cycles" \
            --argjson burst_batch "$BURST_BATCH" \
            --argjson avg_burst_us "$avg_burst_us" \
            '{
               scenario: $scenario,
               transport: $transport,
               bursts: $cycles,
               records_per_burst: $burst_batch,
               avg_burst_latency_us: $avg_burst_us
             }'
        }

        : > "$REPORT"
        echo "[bench] slow-consumer / tcp..."
        run_slow_consumer tcp "127.0.0.1:9092" bp-slow-tcp | tee -a "$REPORT"
        echo "[bench] slow-consumer / uds..."
        run_slow_consumer uds "unix://$SOCK_PATH" bp-slow-uds | tee -a "$REPORT"
        echo "[bench] burst / tcp..."
        run_burst tcp "127.0.0.1:9092" bp-burst-tcp | tee -a "$REPORT"
        echo "[bench] burst / uds..."
        run_burst uds "unix://$SOCK_PATH" bp-burst-uds | tee -a "$REPORT"

        echo ""
        echo "========== Backpressure summary =========="
        jq -s '.' "$REPORT"
      '';
    }
  );

  # Full matrix: warm + cold-nix + cold-all
  bench-matrix = mkApp (
    pkgs.writeShellApplication {
      name = "redpanda-bench-matrix";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.nix
      ];
      text = ''
        echo "========================================="
        echo "  Benchmark Matrix (9 builds total)"
        echo "========================================="
        echo ""

        echo "--- Phase 1: 3x warm (both caches present) ---"
        for i in 1 2 3; do
          echo "=== Warm run $i/3 ==="
          time nix build .#redpanda-cached --print-build-logs
          echo ""
        done

        echo "--- Phase 2: 3x cold-nix (Bazel cache present) ---"
        for i in 1 2 3; do
          echo "=== Cold-nix run $i/3 ==="
          ${mkClear { clearNix = true; }}
          time nix build .#redpanda-cached --print-build-logs
          echo ""
        done

        echo "--- Phase 3: 3x cold-all (no caches) ---"
        for i in 1 2 3; do
          echo "=== Cold-all run $i/3 ==="
          ${mkClear {
            clearNix = true;
            clearBazel = true;
          }}
          time nix build .#redpanda-cached --print-build-logs
          echo ""
        done

        echo "========================================="
        echo "  Matrix complete"
        echo "========================================="
      '';
    }
  );
}
