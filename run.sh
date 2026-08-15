#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="dummy_root-image-riscv-qemu-riscv-virt"
SEARCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_PATH=$(find "$SEARCH_ROOT" -maxdepth 4 -type f -name "$IMAGE_NAME" 2>/dev/null | head -n 1)

if [[ -z "$IMAGE_PATH" ]]; then
    echo "Error: '$IMAGE_NAME' not found under $SEARCH_ROOT" >&2
    exit 1
fi

echo "Using image: $IMAGE_PATH"

qemu-system-riscv64 -M virt -m 3072 -nographic -smp 4 -bios "$IMAGE_PATH"