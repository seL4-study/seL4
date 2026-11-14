#!/bin/sh
set -e

cmake --build build-riscv-qemu
# kernel_all.c(유니티 빌드) 항목을 src/*.c 별 항목으로 펼쳐서 clangd가 커널 소스를 인식하게 함
python3 tools/expand-compile-commands.py build-riscv-qemu
