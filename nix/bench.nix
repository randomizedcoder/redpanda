{ pkgs, flake-utils, redpandaDrv }:

let
  lib = pkgs.lib;

  # The FOD store path — used by clear-bazel to know what to delete
  fodPath = redpandaDrv.passthru.bazelRepoCachePath;

  mkClear = { clearNix ? false, clearBazel ? false }: lib.concatStrings [
    (lib.optionalString clearNix ''
      date -u +%Y-%m-%dT%H:%M:%S.%NZ > nix/entropy
      echo "[bench] Wrote entropy file (Nix cache invalidated)"
    '')
    (lib.optionalString clearBazel ''
      nix store delete ${fodPath} 2>/dev/null || true
      echo "[bench] Deleted FOD store path (Bazel cache invalidated)"
    '')
  ];

  mkBench = { name, clearNix ? false, clearBazel ? false, repeat ? 1 }:
    flake-utils.lib.mkApp {
      drv = pkgs.writeShellApplication {
        name = "redpanda-bench-${name}";
        runtimeInputs = [ pkgs.coreutils pkgs.nix ];
        text = ''
          for i in $(seq 1 ${toString repeat}); do
            echo "=== Run $i/${toString repeat}: ${name} ==="
            ${mkClear { inherit clearNix clearBazel; }}
            echo "[bench] Building..."
            time nix build .#redpanda --print-build-logs
            echo "[bench] Done"
            echo ""
          done
        '';
      };
    };

  mkClearOnly = { name, clearNix ? false, clearBazel ? false }:
    flake-utils.lib.mkApp {
      drv = pkgs.writeShellApplication {
        name = "redpanda-${name}";
        runtimeInputs = [ pkgs.coreutils pkgs.nix ];
        text = mkClear { inherit clearNix clearBazel; };
      };
    };

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

  # Single-run benchmarks
  bench-no-nix = mkBench {
    name = "no-nix";
    clearNix = true;
  };

  bench-no-bazel = mkBench {
    name = "no-bazel";
    clearBazel = true;
  };

  bench-no-cache = mkBench {
    name = "no-cache";
    clearNix = true;
    clearBazel = true;
  };

  bench-cached = mkBench {
    name = "cached";
  };

  # 3x repeated benchmarks
  bench-3x-cached = mkBench {
    name = "3x-cached";
    repeat = 3;
  };

  bench-3x-nix-only = mkBench {
    name = "3x-nix-only";
    clearNix = true;
    repeat = 3;
  };

  bench-3x-bazel-only = mkBench {
    name = "3x-bazel-only";
    clearBazel = true;
    repeat = 3;
  };

  # Matrix: runs 3x-cached + 3x-nix-only + 3x-bazel-only sequentially
  bench-matrix = flake-utils.lib.mkApp {
    drv = pkgs.writeShellApplication {
      name = "redpanda-bench-matrix";
      runtimeInputs = [ pkgs.coreutils pkgs.nix ];
      text = ''
        echo "========================================="
        echo "  Benchmark Matrix (9 builds total)"
        echo "========================================="
        echo ""

        echo "--- Phase 1: 3x fully cached ---"
        for i in 1 2 3; do
          echo "=== Cached run $i/3 ==="
          echo "[bench] Building..."
          time nix build .#redpanda --print-build-logs
          echo "[bench] Done"
          echo ""
        done

        echo "--- Phase 2: 3x Nix cleared, Bazel cached ---"
        for i in 1 2 3; do
          echo "=== Nix-cleared run $i/3 ==="
          date -u +%Y-%m-%dT%H:%M:%S.%NZ > nix/entropy
          echo "[bench] Wrote entropy file (Nix cache invalidated)"
          echo "[bench] Building..."
          time nix build .#redpanda --print-build-logs
          echo "[bench] Done"
          echo ""
        done

        echo "--- Phase 3: 3x Bazel cleared, Nix cached ---"
        for i in 1 2 3; do
          echo "=== Bazel-cleared run $i/3 ==="
          nix store delete ${fodPath} 2>/dev/null || true
          echo "[bench] Deleted FOD store path (Bazel cache invalidated)"
          echo "[bench] Building..."
          time nix build .#redpanda --print-build-logs
          echo "[bench] Done"
          echo ""
        done

        echo "========================================="
        echo "  Matrix complete"
        echo "========================================="
      '';
    };
  };
}
