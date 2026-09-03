#!/bin/bash
# dirtyduck KPM 本地一键构建脚本（Git Bash / WSL / Linux 通用）
#
# 构建环境铁律（2026-09-03 事故定论，详见 TASK_LIST_v0.1.6_T11.md）：
#   - NDK 必须 = 29.0.14206865（clang 21.0.0 r563880c）
#   - KernelPatch 头文件必须 = 固定 ref 0ceeeb968bef86b48af68640af8b135215dc3399
#   用错 KP 头文件编出的模块会在设备上 kprobe 单步死循环挂死（watchdog 重启）！
#
# 用法:
#   ./build_local.sh                # 使用默认路径
#   KP_DIR=/path/to/KernelPatch ./build_local.sh
#   ANDROID_NDK_HOME=/path/to/ndk/29.0.14206865 ./build_local.sh
set -e

cd "$(dirname "$0")"
VERSION=$(grep -m1 'DIRTYDUCK_VERSION :=' Makefile | awk '{print $3}')
echo "[*] building dirtyduck version: $VERSION"

# --- NDK ---
NDK_HOME="${ANDROID_NDK_HOME:-/c/Users/admin/AppData/Local/Android/Sdk/ndk/29.0.14206865}"
CC="$NDK_HOME/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe"
[ -x "$CC" ] || CC="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
[ -x "$CC" ] || { echo "[!] clang not found under NDK: $NDK_HOME"; exit 1; }
"$CC" --version | head -1

# --- KernelPatch headers（固定 ref，不可更换） ---
KP_DIR="${KP_DIR:-$(dirname "$PWD")/KernelPatch-pinned-0ceeeb96}"
[ -d "$KP_DIR/kernel" ] || KP_DIR="$PWD/KernelPatch"
[ -d "$KP_DIR/kernel/patch/include" ] || {
    echo "[!] KernelPatch headers not found at: $KP_DIR"
    echo "    需要的固定 ref: 0ceeeb968bef86b48af68640af8b135215dc3399"
    echo "    获取: git clone https://github.com/bmax121/KernelPatch && cd KernelPatch && git checkout 0ceeeb96"
    echo "    然后: KP_DIR=/path/to/KernelPatch ./build_local.sh"
    exit 1
}
if [ -d "$KP_DIR/.git" ]; then
    HEAD_REF=$(git -C "$KP_DIR" rev-parse HEAD)
    [ "$HEAD_REF" = "0ceeeb968bef86b48af68640af8b135215dc3399" ] || \
        echo "[!] WARN: KernelPatch HEAD=$HEAD_REF 不是固定 ref 0ceeeb96，产物可能挂死设备！"
fi
echo "[*] KP_DIR=$KP_DIR"

# --- build ---
K="$KP_DIR/kernel"
INC="-I$K -I$K/include -I$K/patch/include -I$K/linux -I$K/linux/include \
-I$K/linux/security/selinux/include -I$K/linux/arch/arm64/include -I$K/linux/tools/arch/arm64/include"
CFLAGS="--target=aarch64-linux-android31 -Wall -Wno-typedef-redefinition -O2 -fno-PIC \
-fno-asynchronous-unwind-tables -fno-stack-protector -fno-common -std=gnu99"

cd dirtyduck
"$CC" $CFLAGS -DDIRTYDUCK_VERSION_VALUE=$VERSION -DDIRTYDUCK_HOTPATCH_KP0112=0 \
    $INC -c dirtyduck_selinux.c -o dirtyduck_selinux.o
"$CC" --target=aarch64-linux-android31 -r -nostdlib \
    -o "dirtyduck_selinux_$VERSION.kpm" dirtyduck_selinux.o

echo "[+] built: dirtyduck/dirtyduck_selinux_$VERSION.kpm"
md5sum "dirtyduck_selinux_$VERSION.kpm"
# 0.1.6 设备验证版的参考 MD5: e60c9e61820bef92e0c9f1b8ebdd0977
