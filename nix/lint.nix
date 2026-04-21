# Static-analysis entrypoints, wired into the flake so every
# contributor (and CI) runs the same lint gate as `nix run .#lint`,
# individual per-language runs, and `nix flake check` for a sandboxed
# pass/fail over the Nix source.
#
# Design notes:
#
#   - `apps.lint-*` run against the working tree (the user's checkout),
#     because that is what a developer actually wants to lint before
#     pushing. They exit non-zero on the first violation.
#   - `checks.lint-nix` is a sandboxed derivation that imports a
#     filtered snapshot of the source tree and runs the Nix linters in
#     a pure build; this is what `nix flake check` exercises. Go and
#     C++ linters are left as working-tree apps only because a true
#     sandbox run for them requires Bazel compile_commands.json (C++)
#     and module download access (Go) — both out of scope for a
#     lightweight flake check.
#   - Linter versions are pinned through the flake's nixpkgs input, so
#     `statix-0.5.x`, `deadnix-1.3.x`, `golangci-lint-2.10.x`, etc. are
#     identical for every contributor.

{
  pkgs,
  mkApp,
}:

let
  inherit (pkgs) lib;

  # Filter the tree that `checks.lint-nix` sees. Keep everything that
  # ends in `.nix` or is a directory, drop VCS / build artifacts so
  # sandbox evaluation is reproducible.
  nixSrcOnly = lib.cleanSourceWith {
    name = "redpanda-nix-sources";
    src = ../.;
    filter =
      path: type:
      let
        base = baseNameOf path;
      in
      (
        type == "directory"
        && !lib.elem base [
          ".git"
          "bazel-bin"
          "bazel-out"
          "bazel-redpanda"
          "bazel-testlogs"
          "result"
        ]
      )
      || lib.hasSuffix ".nix" base;
  };

  # Shared shell prelude for the interactive apps: colorized
  # section headers plus a cumulative failure counter so we still
  # surface every linter's output instead of stopping at the first.
  runHeader = ''
    set -u
    FAILED=0
    header() { printf '\n\033[1;34m== %s ==\033[0m\n' "$1"; }
    mark_failure() { FAILED=$((FAILED + 1)); }
    summary() {
      if [ "$FAILED" -eq 0 ]; then
        printf '\n\033[1;32mAll lint checks passed.\033[0m\n'
        exit 0
      else
        printf '\n\033[1;31m%d lint category(ies) failed.\033[0m\n' "$FAILED"
        exit 1
      fi
    }
  '';

  # Files intentionally skipped from lint enforcement. Documented
  # individually so future passes do not silently tolerate new debt.
  #
  #   - MODULE.bazel.lock.nix: generated from Bazel's lockfile, edits
  #     here are overwritten on every `nix build`.
  # Anchored with (^|/) so both find-style (`./nix/MODULE.bazel.lock.nix`)
  # and git-diff-style (`nix/MODULE.bazel.lock.nix`) paths match.
  nixLintSkipRegex = "(^|/)MODULE\\.bazel\\.lock\\.nix$";

  # By default the lint gate only checks files changed on the current
  # branch (vs `origin/dev` if present, else `dev`, else all tracked
  # .nix files). This keeps a PR accountable for its own lint hygiene
  # without forcing it to absorb project-wide pre-existing debt.
  # Set LINT_ALL=1 to scope the lint at the full tree instead — that
  # is the mode CI runs when the repo-wide cleanup lands.
  scopeSelector = ''
    mapfile -t FILES < <(
      if [ "''${LINT_ALL:-0}" = "1" ]; then
        find . \
          -type d \( -name .git -o -name bazel-bin -o -name bazel-out \
            -o -name bazel-redpanda -o -name bazel-testlogs \
            -o -name result -o -name bcr-src \) -prune -o \
          -type f -name '*.nix' -print \
          | grep -Ev '${nixLintSkipRegex}' || true
      else
        # Branch-scoped: changed-vs-merge-base + staged + unstaged.
        # git merge-base picks the fork point against dev; if we are on
        # dev itself the diff is empty so nothing to lint — that is the
        # right answer for an already-merged tree.
        base=$(git merge-base HEAD origin/dev 2>/dev/null \
          || git merge-base HEAD dev 2>/dev/null \
          || git rev-parse HEAD)
        {
          git diff --name-only --diff-filter=AMR "$base" HEAD
          git diff --name-only --diff-filter=AMR --cached
          git diff --name-only --diff-filter=AMR
        } | sort -u \
          | grep -E '\.nix$' \
          | grep -Ev '${nixLintSkipRegex}' \
          | while read -r f; do [ -f "$f" ] && echo "./$f"; done || true
      fi
    )
  '';

  lintNixApp = pkgs.writeShellApplication {
    name = "lint-nix";
    runtimeInputs = [
      pkgs.statix
      pkgs.deadnix
      pkgs.nixfmt
      pkgs.findutils
      pkgs.git
    ];
    text = ''
      ${runHeader}
      ${scopeSelector}

      if [ "''${#FILES[@]}" -eq 0 ]; then
        echo "no .nix files in branch scope; set LINT_ALL=1 to lint the full tree"
        summary
      fi

      echo "linting ''${#FILES[@]} .nix files:"
      printf '  %s\n' "''${FILES[@]}"

      header "statix (anti-patterns)"
      statix_failed=0
      for f in "''${FILES[@]}"; do
        if ! statix check "$f"; then
          statix_failed=1
        fi
      done
      [ "$statix_failed" -eq 0 ] || mark_failure

      header "deadnix (unused bindings)"
      if ! deadnix --fail "''${FILES[@]}"; then
        mark_failure
      fi

      header "nixfmt --check (formatting)"
      if ! nixfmt --check "''${FILES[@]}"; then
        mark_failure
      fi

      summary
    '';
  };

  lintGoApp = pkgs.writeShellApplication {
    name = "lint-go";
    runtimeInputs = [
      pkgs.go
      pkgs.golangci-lint
      pkgs.findutils
    ];
    text = ''
      ${runHeader}
      cd src/go/rpk

      header "gofmt -l"
      unformatted=$(gofmt -l .)
      if [ -n "$unformatted" ]; then
        printf '%s\n' "$unformatted"
        mark_failure
      fi

      header "go vet ./..."
      if ! go vet ./...; then
        mark_failure
      fi

      header "golangci-lint run"
      if ! golangci-lint run --timeout=5m ./...; then
        mark_failure
      fi

      summary
    '';
  };

  lintShellApp = pkgs.writeShellApplication {
    name = "lint-shell";
    runtimeInputs = [
      pkgs.shellcheck
      pkgs.shfmt
      pkgs.findutils
    ];
    text = ''
      ${runHeader}
      # Only standalone .sh scripts — shell embedded inside nix
      # writeShellApplication is shellchecked at build time by nix
      # itself, so this app intentionally skips those.
      mapfile -t FILES < <(
        find . \
          -type d \( -name .git -o -name bazel-bin -o -name bazel-out \
            -o -name bazel-redpanda -o -name bazel-testlogs \
            -o -name result \) -prune -o \
          -type f \( -name '*.sh' -o -name '*.bash' \) -print
      )

      if [ ''${#FILES[@]} -eq 0 ]; then
        header "shellcheck"
        echo "no standalone shell scripts found"
      else
        header "shellcheck (severity: warning)"
        if ! shellcheck -S warning "''${FILES[@]}"; then
          mark_failure
        fi

        header "shfmt -d (diff)"
        if ! shfmt -d "''${FILES[@]}"; then
          mark_failure
        fi
      fi

      summary
    '';
  };

  # C++ format gate. clang-tidy is deliberately *not* run here because
  # it requires a populated compile_commands.json (Bazel-generated),
  # which is a different build dependency graph. Tracking as a
  # follow-up: `bazel run //tools:clang_tidy_all` under Nix once the
  # upstream Bazel target exists.
  lintCcApp = pkgs.writeShellApplication {
    name = "lint-cc";
    runtimeInputs = [
      pkgs.llvmPackages_20.libcxxClang
      pkgs.findutils
      pkgs.git
    ];
    text = ''
      ${runHeader}
      # Branch-scoped like lint-nix: only files changed in this branch.
      # Set LINT_ALL=1 to dry-run the entire src/v tree.
      mapfile -t FILES < <(
        if [ "''${LINT_ALL:-0}" = "1" ]; then
          find src/v -type f \( -name '*.cc' -o -name '*.h' -o -name '*.hh' \) -print
        else
          base=$(git merge-base HEAD origin/dev 2>/dev/null \
            || git merge-base HEAD dev 2>/dev/null \
            || git rev-parse HEAD)
          {
            git diff --name-only --diff-filter=AMR "$base" HEAD
            git diff --name-only --diff-filter=AMR --cached
            git diff --name-only --diff-filter=AMR
          } | sort -u \
            | grep -E '\.(cc|h|hh)$' \
            | while read -r f; do [ -f "$f" ] && echo "$f"; done || true
        fi
      )

      if [ "''${#FILES[@]}" -eq 0 ]; then
        echo "no C++ files in branch scope"
        summary
      fi

      echo "checking ''${#FILES[@]} C++ files"

      header "clang-format --dry-run --Werror"
      fmt_failed=0
      for f in "''${FILES[@]}"; do
        if ! clang-format --dry-run --Werror "$f"; then
          fmt_failed=1
        fi
      done
      [ "$fmt_failed" -eq 0 ] || mark_failure

      summary
    '';
  };

  lintAllApp = pkgs.writeShellApplication {
    name = "lint-all";
    runtimeInputs = [
      lintNixApp
      lintGoApp
      lintShellApp
      lintCcApp
    ];
    text = ''
      set -u
      ALL_FAILED=0
      run_phase() {
        printf '\n\033[1;35m### %s ###\033[0m\n' "$1"
        if ! "$2"; then
          ALL_FAILED=$((ALL_FAILED + 1))
        fi
      }
      run_phase "Nix"    lint-nix
      run_phase "Go"     lint-go
      run_phase "Shell"  lint-shell
      run_phase "C++"    lint-cc

      if [ "$ALL_FAILED" -eq 0 ]; then
        printf '\n\033[1;32m=== lint-all: OK ===\033[0m\n'
        exit 0
      else
        printf '\n\033[1;31m=== lint-all: %d phase(s) failed ===\033[0m\n' "$ALL_FAILED"
        exit 1
      fi
    '';
  };

  # Files this PR author-controls. The sandboxed check enforces the
  # full lint gate (statix + deadnix + nixfmt) against this list.
  # Pre-existing files are intentionally excluded so a UDS PR is not
  # on the hook for a repo-wide Nix-formatting cleanup; that cleanup
  # is a separate change documented in nix/lint.nix follow-ups.
  #
  # Adding a new .nix file? Append it here so the flake check picks
  # it up.
  lintOwnedNixFiles = [
    "nix/lint.nix"
    "nix/tests/uds.nix"
    "nix/tests/checks/uds-checks.nix"
  ];

  # Sandboxed derivation for `nix flake check`. Only Nix files land
  # in the pure build because they are self-contained; Go/C++ linters
  # would pull in a module-cache / compile-commands graph that does
  # not belong in the flake check critical path.
  lintNixCheck =
    pkgs.runCommand "lint-nix-check"
      {
        src = nixSrcOnly;
        nativeBuildInputs = [
          pkgs.statix
          pkgs.deadnix
          pkgs.nixfmt
        ];
        owned = lintOwnedNixFiles;
      }
      ''
        set -euo pipefail
        cd "$src"
        # shellcheck disable=SC2206
        FILES=( $owned )
        echo "linting ''${#FILES[@]} PR-owned .nix files:"
        printf '  %s\n' "''${FILES[@]}"

        echo "== statix =="
        for f in "''${FILES[@]}"; do
          statix check "$f"
        done

        echo "== deadnix =="
        deadnix --fail "''${FILES[@]}"

        echo "== nixfmt --check =="
        nixfmt --check "''${FILES[@]}"

        touch "$out"
      '';
in
{
  apps = {
    lint = mkApp lintAllApp;
    lint-nix = mkApp lintNixApp;
    lint-go = mkApp lintGoApp;
    lint-shell = mkApp lintShellApp;
    lint-cc = mkApp lintCcApp;
  };

  checks = {
    lint-nix = lintNixCheck;
  };
}
