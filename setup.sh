#!/usr/bin/env bash
#
# Sets up qemu-riscv-virt/riscv64 development for this seL4 kernel checkout:
#   - a compile_commands.json + .clangd/.vscode config, so clangd works on the
#     kernel sources (including per-file entries for the kernel's unity build)
#   - a bootable QEMU image proving the real boot chain (kernel + ElfLoader +
#     OpenSBI) actually works, verified by booting it and checking for the
#     kernel's own "dropped to user space" boot message
#
# No application/root task is built - DeclareRootserver just wraps a tiny stub
# whose only job is to exist as a valid ELF entry point, so this only proves
# the kernel boots and hands control to userspace, not a running system.
#
# Run this from anywhere inside the seL4 kernel checkout it should configure.
# Safe to re-run: existing clones/config are reused rather than recreated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"

if [ ! -f "$REPO_ROOT/FindseL4.cmake" ] || [ ! -d "$REPO_ROOT/libsel4" ]; then
    echo "error: $REPO_ROOT does not look like an seL4 kernel checkout" \
         "(expected FindseL4.cmake and libsel4/ at its root)" >&2
    exit 1
fi
cd "$REPO_ROOT"

DEPS_DIR="$REPO_ROOT/.riscv-qemu"
BUILD_DIR="$REPO_ROOT/build-riscv-qemu"
BUILD_DIR_NAME="$(basename "$BUILD_DIR")"

log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

ask_yes_no() {
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# 1. Dependencies: check, then ask before installing anything
# ---------------------------------------------------------------------------
log "Checking dependencies"

declare -A BIN_TO_PKG=(
    [git]=git
    [make]=make
    [cmake]=cmake
    [ninja]=ninja-build
    [riscv64-linux-gnu-gcc]=gcc-riscv64-linux-gnu
    [riscv64-linux-gnu-ld]=binutils-riscv64-linux-gnu
    [qemu-system-riscv64]=qemu-system-misc
    [dtc]=device-tree-compiler
    [xmllint]=libxml2-utils
    [clangd]=clangd
    [cpio]=cpio
)
declare -A PYMOD_TO_PKG=(
    [yaml]=python3-yaml
    [jinja2]=python3-jinja2
    [ply]=python3-ply
    [lxml]=python3-lxml
    [libarchive]=python3-libarchive-c
    [elftools]=python3-pyelftools
)

missing_apt=()
for bin in "${!BIN_TO_PKG[@]}"; do
    command -v "$bin" >/dev/null 2>&1 || missing_apt+=("${BIN_TO_PKG[$bin]}")
done
for mod in "${!PYMOD_TO_PKG[@]}"; do
    python3 -c "import $mod" >/dev/null 2>&1 || missing_apt+=("${PYMOD_TO_PKG[$mod]}")
done

if [ ${#missing_apt[@]} -gt 0 ]; then
    mapfile -t missing_apt < <(printf '%s\n' "${missing_apt[@]}" | sort -u)
    echo "Missing packages: ${missing_apt[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        if ask_yes_no "Install with 'sudo apt-get install -y ${missing_apt[*]}'?"; then
            sudo apt-get update
            sudo apt-get install -y "${missing_apt[@]}"
        else
            echo "error: cannot continue without these packages" >&2
            exit 1
        fi
    else
        echo "error: apt-get not found on this system. Install the packages listed" >&2
        echo "above (or your distro's equivalents) yourself, then re-run this script." >&2
        exit 1
    fi
else
    echo "All system/python packages already present."
fi

if ! python3 -c "import pyfdt" >/dev/null 2>&1; then
    echo "Missing python module 'pyfdt' (no apt package for it; installed via pip)"
    if ask_yes_no "Install with 'pip3 install --break-system-packages pyfdt'?"; then
        pip3 install --break-system-packages pyfdt
    else
        echo "error: cannot continue without pyfdt" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 2. Fetch seL4_tools / util_libs (elfloader-tool, cmake-tool, libcpio) and
#    OpenSBI. Pinned to what seL4's own sel4test-manifest uses, since a newer
#    OpenSBI (post-v0.9) requires a PIE-capable toolchain and links itself as
#    PIE; QEMU's "-bios <elf>" loader doesn't rebase a PIE image, so it ends up
#    loaded at the wrong physical address and silently never executes.
# ---------------------------------------------------------------------------
log "Fetching seL4_tools, util_libs, opensbi"
mkdir -p "$DEPS_DIR/tools"

clone_if_missing() {
    local dir="$1" url="$2" branch="$3"
    if [ -d "$dir/.git" ]; then
        echo "  $(basename "$dir") already present, skipping clone"
    else
        git clone --quiet --depth 1 --branch "$branch" "$url" "$dir"
    fi
}

clone_if_missing "$DEPS_DIR/tools/seL4_tools" https://github.com/seL4/seL4_tools.git master
clone_if_missing "$DEPS_DIR/tools/util_libs" https://github.com/seL4/util_libs.git master
clone_if_missing "$DEPS_DIR/tools/opensbi" https://github.com/riscv-software-src/opensbi.git v0.9

# ---------------------------------------------------------------------------
# 3. Wrapper CMake project: this kernel repo is a standalone CMake project on
#    its own (no application/root task), so a small wrapper project is needed
#    to pull in libsel4 + elfloader-tool + util_libs and package a bootable
#    image via cmake-tool's DeclareRootserver().
# ---------------------------------------------------------------------------
log "Writing wrapper CMake project"

cat > "$DEPS_DIR/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16.0)
project(sel4-riscv-qemu-boot C ASM)

set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH}
    "${CMAKE_CURRENT_SOURCE_DIR}/.."
    "${CMAKE_CURRENT_SOURCE_DIR}/tools/seL4_tools/elfloader-tool"
    "${CMAKE_CURRENT_SOURCE_DIR}/tools/seL4_tools/cmake-tool/helpers"
    "${CMAKE_CURRENT_SOURCE_DIR}/tools/util_libs"
)
find_package(seL4 REQUIRED)
find_package(elfloader-tool REQUIRED)
find_package(util_libs REQUIRED)

# util_libs targets (e.g. libcpio) don't otherwise inherit the freestanding
# flags the kernel/elfloader apply to their own sources, and fail to link
# with undefined __stack_chk_guard/__stack_chk_fail against -nostdlib.
add_compile_options(-fno-stack-protector)

sel4_import_kernel()
sel4_import_libsel4()
util_libs_import_libraries()
elfloader_import_project()

include(${CMAKE_CURRENT_SOURCE_DIR}/tools/seL4_tools/cmake-tool/helpers/rootserver.cmake)

# No real application: this stub only exists so DeclareRootserver has a valid
# ELF (with a _sel4_start entry point) to package into a bootable image. It
# proves the kernel boots and hands control to userspace; nothing more.
add_executable(dummy_root EXCLUDE_FROM_ALL dummy_root.S)
target_link_options(dummy_root PRIVATE -nostdlib -static)
DeclareRootserver(dummy_root)
EOF

cat > "$DEPS_DIR/dummy_root.S" <<'EOF'
.section .text
.global _sel4_start
_sel4_start:
1:
    j 1b
EOF

# ---------------------------------------------------------------------------
# 4. Configure + build
# ---------------------------------------------------------------------------
log "Configuring (qemu-riscv-virt, riscv64, SMP=4)"
cmake -S "$DEPS_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$REPO_ROOT/gcc.cmake" -DRISCV64=TRUE \
    -DKernelPlatform=qemu-riscv-virt -DKernelSel4Arch=riscv64 \
    -DKernelMaxNumNodes=4 -DKernelVerificationBuild=OFF \
    -DKernelIsMCS=ON \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

log "Building kernel + libsel4 + elfloader + OpenSBI"
cmake --build "$BUILD_DIR"

# ---------------------------------------------------------------------------
# 5. clangd: expand the kernel's unity-build compile_commands.json entry into
#    one entry per source file (kernel/CMakeLists.txt concatenates all of
#    kernel/src/**/*.c into a single kernel_all.c translation unit).
# ---------------------------------------------------------------------------
log "Setting up clangd"

if [ ! -f "$REPO_ROOT/tools/expand-compile-commands.py" ]; then
cat > "$REPO_ROOT/tools/expand-compile-commands.py" <<'PYEOF'
#!/usr/bin/env python3
"""Expand compile_commands.json's kernel_all.c unity-build entry into per-source-file entries."""
import argparse
import copy
import json
import re
import sys
from pathlib import Path

LINE_MARKER_RE = re.compile(r'^#line \d+ "(.*)"')


def find_unity_entry(entries):
    matches = [e for e in entries if Path(e["file"]).name == "kernel_all.c"]
    if not matches:
        sys.exit("no kernel_all.c entry in compile_commands.json - build kernel.elf first")
    if len(matches) > 1:
        sys.exit("multiple kernel_all.c entries found, expected exactly one")
    return matches[0]


def resolve(path, directory):
    p = Path(path)
    return str(p if p.is_absolute() else Path(directory) / p)


def discover_source_files(kernel_all_c):
    seen = []
    with open(kernel_all_c) as f:
        for line in f:
            m = LINE_MARKER_RE.match(line)
            if m and m.group(1) not in seen:
                seen.append(m.group(1))
    return seen


def clone_entry_for_file(unity_entry, kernel_all_c, target_file):
    entry = copy.deepcopy(unity_entry)
    entry["file"] = target_file
    if "command" in entry:
        entry["command"] = entry["command"].replace(kernel_all_c, target_file)
    if "arguments" in entry:
        entry["arguments"] = [target_file if a == kernel_all_c else a for a in entry["arguments"]]
    return entry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_dir", help="CMake build directory containing compile_commands.json")
    args = parser.parse_args()

    db_path = Path(args.build_dir) / "compile_commands.json"
    if not db_path.exists():
        sys.exit(f"{db_path} not found")

    entries = json.loads(db_path.read_text())
    unity_entry = find_unity_entry(entries)
    kernel_all_c = resolve(unity_entry["file"], unity_entry["directory"])

    source_files = discover_source_files(kernel_all_c)
    if not source_files:
        sys.exit(f"no '#line' markers found in {kernel_all_c}")

    stale = {resolve(f, unity_entry["directory"]) for f in source_files} | {kernel_all_c}
    kept = [e for e in entries if resolve(e["file"], e["directory"]) not in stale]
    expanded = [clone_entry_for_file(unity_entry, kernel_all_c, f) for f in source_files]

    db_path.write_text(json.dumps(kept + [unity_entry] + expanded, indent=2))
    print(f"expanded {len(source_files)} files from kernel_all.c into {db_path}")


if __name__ == "__main__":
    main()
PYEOF
chmod +x "$REPO_ROOT/tools/expand-compile-commands.py"
fi

python3 "$REPO_ROOT/tools/expand-compile-commands.py" "$BUILD_DIR_NAME"

cat > "$REPO_ROOT/.clangd" <<EOF
CompileFlags:
  CompilationDatabase: $BUILD_DIR_NAME
  Remove: [-Werror]
EOF

mkdir -p "$REPO_ROOT/.vscode"
cat > "$REPO_ROOT/.vscode/settings.json" <<EOF
{
  "clangd.arguments": ["--compile-commands-dir=\${workspaceFolder}/$BUILD_DIR_NAME", "--background-index"],
  "C_Cpp.intelliSenseEngine": "disabled"
}
EOF

if ! grep -q "riscv-qemu build artifacts" "$REPO_ROOT/.gitignore" 2>/dev/null; then
    {
        echo ""
        echo "# RISC-V QEMU build artifacts"
        echo "/$(basename "$DEPS_DIR")/"
        echo "/$BUILD_DIR_NAME/"
    } >> "$REPO_ROOT/.gitignore"
fi

# ---------------------------------------------------------------------------
# 6. Boot the image in QEMU and check for the kernel's own boot messages
#    (src/arch/riscv/kernel/boot.c) to confirm the whole pipeline works.
# ---------------------------------------------------------------------------
log "Booting in QEMU to verify the pipeline"

IMAGE="$BUILD_DIR/images/dummy_root-image-riscv-qemu-riscv-virt"
if [ ! -f "$IMAGE" ]; then
    echo "error: expected image not found at $IMAGE" >&2
    exit 1
fi

BOOT_LOG="$(mktemp)"
trap 'rm -f "$BOOT_LOG"' EXIT

# dummy_root loops forever once booted, so qemu never exits on its own - poll
# the log and stop as soon as the kernel's own success message shows up,
# instead of waiting out a fixed timeout and only checking at the end. This
# detects success in ~1s on a normal boot while still tolerating a much
# slower one (e.g. right after a large build, while the host is still busy).
MAX_WAIT_SECS=45
qemu-system-riscv64 -M virt -m 3072 -nographic -smp 4 -bios "$IMAGE" \
    > "$BOOT_LOG" 2>&1 &
qemu_pid=$!

boot_ok=0
waited=0
while [ "$waited" -lt "$MAX_WAIT_SECS" ]; do
    if grep -q "Booting all finished, dropped to user space" "$BOOT_LOG" 2>/dev/null; then
        boot_ok=1
        break
    fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        # qemu exited on its own (crash?) before printing the success marker
        break
    fi
    sleep 1
    waited=$((waited + 1))
done

kill "$qemu_pid" 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true

if [ "$boot_ok" -eq 1 ]; then
    echo "Boot verified: OpenSBI -> ElfLoader -> kernel -> userspace all succeeded."
else
    echo "warning: could not confirm a successful boot within ${MAX_WAIT_SECS}s. QEMU output:" >&2
    cat "$BOOT_LOG" >&2
    exit 1
fi

log "Done"
cat <<MSG
clangd is configured - open any kernel .c file in VSCode (restart the clangd
language server if it was already running).

To rebuild the kernel and refresh clangd's per-file compile commands:
  cmake --build $BUILD_DIR_NAME
  python3 tools/expand-compile-commands.py $BUILD_DIR_NAME

Boot the image again anytime with:
  qemu-system-riscv64 -M virt -m 3072 -nographic -smp 4 -bios $IMAGE
MSG

