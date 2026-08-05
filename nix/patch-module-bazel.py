#!/usr/bin/env python3
"""Patch MODULE.bazel for Nix sandbox build.

Removes dev_dependency extensions not needed for //src/v/redpanda:redpanda
and applies other Nix-specific patches.

Extensions REMOVED:
  - buildifier_prebuilt (dev, code formatter)
  - rules_shell (dev, shell rules)
  - toolchains_llvm + LLVM section (dev, CI LLVM — use system-clang)
  - rules_oci + OCI section (dev, Docker images)

Extensions REMOVED (pip replaced with nixpkgs):
  - pip (replaced by nixpkgs python packages via stub extension)

Extensions KEPT:
  - go_sdk (dev, provides Go toolchain via host())
  - go_deps (non-dev, provides @org_golang_google_protobuf for pbgen)
  - rust (dev, compiles wasmtime_c)
  - crate (non-dev, provides wasmtime_c source)
  - python (dev, toolchain for code gen)

Other patches:
  - go_sdk.download() → go_sdk.host() (use Go from PATH)
  - Remove go_sdk_with_systemcrypto block
  - Add rules_buf override (stub downloads)
  - Add rules_cc override (fix shebangs)
  - Replace pip extension with stub @python_deps repo (nixpkgs provides packages)

Usage: python3 nix/patch-module-bazel.py MODULE.bazel
"""

import re
import sys


def main():
    path = sys.argv[1]
    with open(path) as f:
        lines = f.read().split('\n')

    output = []
    i = 0

    def skip_block(idx):
        """Skip from current line through matching close paren/bracket."""
        depth = 0
        started = False
        while idx < len(lines):
            for ch in lines[idx]:
                if ch in '([':
                    depth += 1
                    started = True
                elif ch in ')]':
                    depth -= 1
            idx += 1
            if started and depth <= 0:
                break
        return idx

    def peek_block(idx):
        """Return the text of the block starting at idx."""
        j = idx
        block = []
        depth = 0
        started = False
        while j < len(lines):
            block.append(lines[j])
            for ch in lines[j]:
                if ch in '([':
                    depth += 1
                    started = True
                elif ch in ')]':
                    depth -= 1
            j += 1
            if started and depth <= 0:
                break
        return '\n'.join(block), j

    def is_section_header(idx, title):
        """Check if idx..idx+2 is a ====\ntitle\n==== section header."""
        if idx + 1 >= len(lines):
            return False
        return (lines[idx].strip().startswith('# ====')
                and title.lower() in lines[idx + 1].lower())

    while i < len(lines):
        line = lines[i]

        # ── Remove buildifier_prebuilt bazel_dep ──
        if 'bazel_dep(name = "buildifier_prebuilt"' in line:
            i = skip_block(i)
            continue

        # Remove its single_version_override
        if 'single_version_override(' in line:
            block_text, j = peek_block(i)
            if '"buildifier_prebuilt"' in block_text:
                i = j
                continue

        # ── Remove rules_shell ──
        if 'bazel_dep(name = "rules_shell"' in line:
            i += 1
            continue

        # ── Remove toolchains_llvm bazel_dep ──
        if 'bazel_dep(name = "toolchains_llvm"' in line:
            i = skip_block(i)
            continue

        # Remove toolchains_llvm archive_override
        if 'archive_override(' in line:
            block_text, j = peek_block(i)
            if '"toolchains_llvm"' in block_text:
                i = j
                continue

        # ── Remove entire LLVM toolchain section ──
        if is_section_header(i, 'llvm toolchain'):
            # Skip header (====, title, ====)
            i += 2
            if i < len(lines) and lines[i].strip().startswith('# ===='):
                i += 1
            # Skip blank lines
            while i < len(lines) and lines[i].strip() == '':
                i += 1
            # Skip everything until next section
            while i < len(lines):
                if is_section_header(i, 'go toolchain'):
                    break
                if is_section_header(i, 'rust toolchain'):
                    break
                i += 1
            continue

        # ── Replace go_sdk.download() with go_sdk.host() ──
        if 'go_sdk = use_extension(' in line:
            output.append('go_sdk = use_extension("@rules_go//go:extensions.bzl", "go_sdk", dev_dependency = True)')
            i = skip_block(i)
            # Skip go_sdk.download/nogo/host calls and replace with host()
            while i < len(lines) and (lines[i].strip().startswith('go_sdk.') or lines[i].strip() == ''):
                if lines[i].strip().startswith('go_sdk.'):
                    i = skip_block(i)
                else:
                    i += 1
            output.append('go_sdk.host()')
            output.append('')
            continue

        # ── Remove go_sdk_with_systemcrypto block ──
        if '# The microsoft compiler versions' in line:
            # Skip until the closing ) of the go_sdk block
            while i < len(lines):
                if lines[i].strip() == ')' and i > 0 and 'go_sdk' in '\n'.join(lines[max(0,i-10):i]):
                    i += 1
                    break
                i += 1
            continue

        # ── Remove OCI section ──
        if is_section_header(i, 'oci base images'):
            i += 2
            if i < len(lines) and lines[i].strip().startswith('# ===='):
                i += 1
            # Skip everything until http_file/http_archive declarations
            while i < len(lines):
                if lines[i].strip().startswith('http_file') or lines[i].strip().startswith('http_archive'):
                    break
                if is_section_header(i, ''):
                    break
                i += 1
            continue

        # Remove rules_oci bazel_dep
        if 'bazel_dep(name = "rules_oci"' in line:
            i += 1
            continue

        # Remove oci extension and its use_repo
        if 'oci = use_extension(' in line:
            i = skip_block(i)
            continue
        if line.strip().startswith('oci.'):
            i = skip_block(i)
            continue
        if 'use_repo(' in line:
            block_text, j = peek_block(i)
            if re.search(r'\boci\b', block_text) and 'rules_oci' not in block_text:
                i = j
                continue

        # Remove register_toolchains for llvm
        if 'register_toolchains(' in line and 'llvm_toolchain' in line:
            i = skip_block(i)
            continue

        # ── Remove pip extension (replaced by nixpkgs packages) ──
        if 'pip = use_extension(' in line:
            i = skip_block(i)
            continue
        if line.strip().startswith('pip.'):
            i = skip_block(i)
            continue
        if 'use_repo(' in line:
            block_text, j = peek_block(i)
            if re.search(r'\bpip\b', block_text) and 'rules_python' not in block_text and 'pip_tools' not in block_text:
                i = j
                continue

        # ── Remove rust toolchain + crate_universe extensions ──
        # The nix branch substitutes @crates//:wasmtime_c with a pre-built
        # wasmtime C API tarball (see nix_wasmtime/). No rust code in
        # redpanda needs to compile, so rust toolchain + crate fetching
        # can be skipped entirely.
        if 'rust = use_extension(' in line:
            i = skip_block(i)
            continue
        if line.strip().startswith('rust.'):
            i = skip_block(i)
            continue
        if 'crate = use_extension(' in line:
            i = skip_block(i)
            continue
        if line.strip().startswith('crate.'):
            i = skip_block(i)
            continue
        # Strip section header comments for rust/crate sections
        if is_section_header(i, 'rust toolchain'):
            i += 2
            if i < len(lines) and lines[i].strip().startswith('# ===='):
                i += 1
            while i < len(lines) and lines[i].strip() == '':
                i += 1
            while i < len(lines):
                if is_section_header(i, ''):
                    break
                i += 1
            continue
        if 'use_repo(' in line:
            block_text, j = peek_block(i)
            if re.search(r'\b(rust|crate)\b', block_text) and 'rules_rust' not in block_text:
                i = j
                continue
        if 'register_toolchains(' in line and 'rust_toolchains' in line:
            i = skip_block(i)
            continue

        output.append(line)
        i += 1

    text = '\n'.join(output)

    # Clean up multiple blank lines
    text = re.sub(r'\n{3,}', '\n\n', text)

    # ── Add Nix-specific overrides ──
    if 'module_name = "rules_buf"' not in text:
        text += '''
# Nix: stub out buf toolchain downloads (not needed for the build)
single_version_override(
    module_name = "rules_buf",
    patch_strip = 1,
    patches = ["//bazel/thirdparty:rules_buf-nix-no-download.patch"],
)
'''

    # ── py_binary launcher shebang ──
    # rules_python emits py_binary launchers with a `#!/usr/bin/env python3`
    # shebang (DEFAULT_STUB_SHEBANG, plus a hardcoded prelude). The Nix build
    # sandbox has no /usr/bin/env, so every py_binary used as a build tool
    # (seastar-json2code, the rpc compiler, the schemata generator, the version
    # stamper, ...) fails with "bad interpreter". These launchers are written by
    # build actions in bazel-out, after the nixify shebang-fix pass runs over
    # external/, so nixify can't reach them. Instead rewrite the shebang default
    # in rules_python itself at repo-setup time. @NIX_STUB_PYTHON@ is replaced
    # with the nixpkgs python store path by redpanda.nix.
    if 'module_name = "rules_python"' not in text:
        text += '''
single_version_override(
    module_name = "rules_python",
    patch_cmds = [
        "find python -name '*.bzl' -exec sed -i 's|#!/usr/bin/env python3|#!@NIX_STUB_PYTHON@/bin/python3|g' {} +",
    ],
)
'''

    # ── Local (nixpkgs) python toolchain ──
    # The hermetic python.toolchain() interpreter lives in each py_binary's
    # runfiles (rules_python++python+.../bin/python3). Those runfiles are not
    # materialized when a py_binary runs as a genrule *tool* under
    # --spawn_strategy=local, so the launcher's re-exec fails with
    # FileNotFoundError. Register a local runtime pointing at the nixpkgs python
    # (absolute store path, substituted by redpanda.nix) — its interpreter is an
    # absolute path, needing no runfiles — and give it toolchain priority via a
    # root-module register_toolchains().
    if 'local_runtime_repo' not in text:
        text += '''
local_runtime_repo = use_repo_rule("@rules_python//python/private:local_runtime_repo.bzl", "local_runtime_repo")
local_runtime_toolchains_repo = use_repo_rule("@rules_python//python/private:local_runtime_toolchains_repo.bzl", "local_runtime_toolchains_repo")
local_runtime_repo(
    name = "nix_python3",
    interpreter_path = "@NIX_STUB_PYTHON@/bin/python3",
    on_failure = "fail",
)
local_runtime_toolchains_repo(
    name = "nix_python_toolchains",
    runtimes = ["nix_python3"],
)
register_toolchains("@nix_python_toolchains//:all")
'''

    # ── Replace pip with stub python_deps extension ──
    # nixpkgs provides jinja2/jsonschema via python312.withPackages.
    # The stub extension creates empty py_library targets so Bazel can
    # resolve @python_deps//jinja2 etc. — the real packages are on sys.path.
    if 'python_deps_ext' not in text:
        text += '''
# Nix: stub @python_deps repo (real packages from nixpkgs system Python)
python_deps = use_extension("//bazel:python_deps.bzl", "python_deps_ext")
use_repo(python_deps, "python_deps")
'''

    # ── Table-driven module shebang fixes ──
    # Each entry: (module_name, files, search_name, replacement)
    # search_name is the interpreter to match (e.g. "bash", "perl")
    # The sed pattern `s|#!.*<search_name>|#!<replacement>|g` replaces
    # #!...<search_name> with #!<replacement> wherever it appears.
    # Works for line-1 shebangs AND embedded shebangs in .bzl templates
    # (e.g. `return "#!/usr/bin/env bash"`).
    #
    # To add a new module, just add an entry to this table.
    MODULE_SHEBANG_FIXES = [
        # (module, files_to_fix, search_name, replacement)
        # search_name: the interpreter name to look for in shebangs (e.g. "bash")
        # replacement: what to put after #! (e.g. "$BAZEL_SH" which Nix sets)
        ("rules_foreign_cc", [
            "foreign_cc/private/framework/toolchains/linux_commands.bzl",
            "foreign_cc/private/framework/toolchains/macos_commands.bzl",
            "foreign_cc/private/framework/toolchains/freebsd_commands.bzl",
            "foreign_cc/private/runnable_binary_wrapper.sh",
        ], "bash", "$BAZEL_SH"),
        ("rules_cc", [
            "cc/private/toolchain/generate_system_module_map.sh",
            "cc/private/toolchain/grep-includes.sh",
            "cc/private/toolchain/link_dynamic_library.sh",
        ], "bash", "$BAZEL_SH"),
    ]

    for module, files, search_name, replacement in MODULE_SHEBANG_FIXES:
        if f'module_name = "{module}"' not in text:
            files_str = ' '.join(files)
            text += f'''
# Nix: fix shebangs in {module}.
# Replace #!...{search_name} with #!{replacement} (handles embedded shebangs in .bzl too).
single_version_override(
    module_name = "{module}",
    patch_cmds = [
        "sed -i \\"s|#!.*{search_name}|#!{replacement}|g\\" {files_str}",
    ],
)
'''

    # ── Pre-built protoc toolchain ──
    # Register nix_protoc toolchain FIRST so it has highest priority.
    # This uses nixpkgs protoc instead of compiling it from source (~240 actions saved).
    # Must go right after the module() block.
    if 'nix_protoc' not in text:
        text = text.replace(
            'module(\n    name = "redpanda",\n    repo_name = "com_github_redpanda_data_redpanda",\n)',
            'module(\n    name = "redpanda",\n    repo_name = "com_github_redpanda_data_redpanda",\n)\n\nregister_toolchains("//nix_protoc:nix_protoc_toolchain")',
            1,
        )

    # Fix liburing undeclared inclusion of config-host.h.
    # Upstream's liburing.patch switched the generate_headers genrule to an
    # out-of-source build: `configure` now writes config-host.h into the genrule
    # CWD (the exec root), not the package dir. With --spawn_strategy=local that
    # file persists in the workspace, and the `uring` library's
    # `-include config-host.h` picks up the leaked copy instead of the declared
    # genrule output, tripping Bazel's undeclared-inclusion check. Clean it up
    # right after the "collect the outputs" loop (CWD is the exec root there).
    #
    # Upstream now ships its own single_version_override for liburing
    # (patches = [liburing.patch]); Bazel forbids a second override for the same
    # module, so inject patch_cmds into the existing one rather than appending.
    liburing_patch_cmds = '''    patch_cmds = [
        "sed -i '/^            done$/a\\\\            rm -f config-host.h config-host.mak' BUILD.bazel",
    ],
'''
    if 'config-host.h' not in text:
        if 'module_name = "liburing"' in text:
            idx = text.index('module_name = "liburing"')
            close = text.index('\n)', idx)
            text = text[:close + 1] + liburing_patch_cmds + text[close + 1:]
        else:
            text += ('\nsingle_version_override(\n'
                     '    module_name = "liburing",\n'
                     + liburing_patch_cmds + ')\n')

    with open(path, 'w') as f:
        f.write(text)

    print(f"Patched {path}", file=sys.stderr)


if __name__ == '__main__':
    main()
