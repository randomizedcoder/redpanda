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

    # Fix rules_foreign_cc shebangs: /usr/bin/env doesn't exist in Nix sandbox.
    # Replace #!/usr/bin/env bash with #!$BAZEL_SH (the Nix bash path).
    # Bazel runs wrapper scripts via explicit bash, so the shebang is just a
    # comment — but some scripts may be exec'd directly, so use the real path.
    if 'module_name = "rules_foreign_cc"' not in text:
        text += '''
# Nix: fix shebangs in rules_foreign_cc.
# /usr/bin/env doesn't exist in Nix sandbox. Use $BAZEL_SH (Nix bash path).
single_version_override(
    module_name = "rules_foreign_cc",
    patch_cmds = [
        "sed -i \\"s|#!/usr/bin/env bash|#!$BAZEL_SH|g\\" foreign_cc/private/framework/toolchains/linux_commands.bzl foreign_cc/private/framework/toolchains/macos_commands.bzl foreign_cc/private/framework/toolchains/freebsd_commands.bzl foreign_cc/private/runnable_binary_wrapper.sh",
    ],
)
'''

    # Fix rules_cc shebangs: ensure $BAZEL_SH is used (not /bin/sh)
    rules_cc_override = '''
# Nix: fix shebangs in rules_cc toolchain scripts.
# In Nix sandbox, /bin/sh is NOT bash (it's dash/busybox), but these scripts
# use bash-specific features ([[ ]], $OSTYPE, etc.). Replace all shell shebangs
# with $BAZEL_SH which points to the real Nix bash.
single_version_override(
    module_name = "rules_cc",
    patch_cmds = [
        "sed -i \\"1s|^#!.*|#!$BAZEL_SH|\\" cc/private/toolchain/generate_system_module_map.sh cc/private/toolchain/grep-includes.sh cc/private/toolchain/link_dynamic_library.sh",
    ],
)
'''
    if 'module_name = "rules_cc"' not in text:
        text += rules_cc_override
    elif '#!/bin/sh' in text and 'module_name = "rules_cc"' in text:
        # Replace old /bin/sh version with $BAZEL_SH version
        text = re.sub(
            r'# Nix:.*?rules_cc.*?\nsingle_version_override\(\s*\n\s*module_name = "rules_cc".*?\n.*?\n\s*\]\s*,\s*\n\s*\)',
            rules_cc_override.strip(),
            text,
            flags=re.DOTALL,
        )

    with open(path, 'w') as f:
        f.write(text)

    print(f"Patched {path}", file=sys.stderr)


if __name__ == '__main__':
    main()
