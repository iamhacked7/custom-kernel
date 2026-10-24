#!/usr/bin/env bash
# Assembles the kernel source tree for the A52 4G (a52q / SM7125 "atoll").
#
# Component choices are all verified, not assumed:
#   - LineageOS sm7125 tree is the clean upstream base; it carries
#     lineage-a52q_defconfig and has 0 files matching susfs or kernelsu, so it
#     supplies no root solution of its own. ProtonPlus-Resurrected (73,801
#     files) is this tree (73,783) plus exactly that integration.
#   - KernelSU-Next is the only option here: official KernelSU dropped non-GKI
#     after v0.9.5, and BakaSU's tracepoint hook is GKI2 (5.10+) only.
#   - susfs4ksu branch kernel-4.14 is frozen at v1.5.5 (last commit
#     2025-02-23); the newer v1.5.9/v1.5.11 live only on GKI branches, so
#     v1.5.5 is the ceiling for a 4.14 non-GKI kernel.
#   - Hook mode is MANUAL because susfs4ksu's own non-GKI instructions say to
#     disable kprobe hooks. CONFIG_KPROBES stays on for our tracing.
set -euo pipefail

ROOT="${1:-$PWD/a52q-kernel}"
KSU_TAG="${KSU_TAG:-v3.4.2}"
SUSFS_BRANCH="kernel-4.14"
LINEAGE_BRANCH="${LINEAGE_BRANCH:-lineage-22.1}"
DEFCONFIG="arch/arm64/configs/vendor/lineage-a52q_defconfig"
FRAGMENT="$(cd "$(dirname "$0")" && pwd)/defconfig_fragment.txt"

say() { printf '\n== %s\n' "$*"; }

say "1/5  kernel source (LineageOS sm7125, $LINEAGE_BRANCH)"
if [ ! -d "$ROOT" ]; then
    git clone --depth=1 -b "$LINEAGE_BRANCH" \
        https://github.com/LineageOS/android_kernel_samsung_sm7125 "$ROOT"
else
    echo "   sudah ada, dilewati"
fi
cd "$ROOT"
[ -f "$DEFCONFIG" ] || { echo "!! $DEFCONFIG tidak ada - cek nama branch"; exit 1; }

say "2/5  KernelSU-Next $KSU_TAG"
rm -rf KernelSU-Next
git clone --depth=1 -b "$KSU_TAG" \
    https://github.com/KernelSU-Next/KernelSU-Next.git KernelSU-Next
# The kernel build expects the driver at drivers/kernelsu.
ln -sfn "../KernelSU-Next/kernel" drivers/kernelsu
grep -q 'kernelsu' drivers/Makefile || \
    echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
grep -q 'kernelsu' drivers/Kconfig || \
    sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig

say "3/5  susfs4ksu ($SUSFS_BRANCH, v1.5.5)"
rm -rf /tmp/susfs4ksu
git clone --depth=1 -b "$SUSFS_BRANCH" \
    https://gitlab.com/simonpunk/susfs4ksu.git /tmp/susfs4ksu
cp -v /tmp/susfs4ksu/kernel_patches/fs/* fs/
cp -v /tmp/susfs4ksu/kernel_patches/include/linux/* include/linux/
cp -v /tmp/susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch KernelSU-Next/
cp -v /tmp/susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.14.patch ./

say "4/5  terapkan patch"
( cd KernelSU-Next && patch -p1 --forward < 10_enable_susfs_for_ksu.patch ) || \
    echo "   !! sebagian patch KSU gagal - rapikan manual (wajar, tree berbeda)"
patch -p1 --forward < 50_add_susfs_in_kernel-4.14.patch || \
    echo "   !! sebagian patch kernel gagal - rapikan manual"

# susfs4ksu's non-GKI instruction step 4: stop KernelSU using kprobe hooks.
say "     matikan kprobe hook di KernelSU (syarat non-GKI susfs)"
grep -rl '#ifdef CONFIG_KPROBES' KernelSU-Next/kernel/ 2>/dev/null | while read -r f; do
    sed -i 's/#ifdef CONFIG_KPROBES/#if defined(CONFIG_KPROBES) \&\& 0/g' "$f"
    echo "   -> $f"
done

say "5/5  defconfig"
cp -f "$DEFCONFIG" "$DEFCONFIG.orig"
# Drop any existing setting for a key we are about to define, then append.
grep -vE '^#?\s*(CONFIG_KPROBES|CONFIG_KPROBE_EVENTS|CONFIG_KRETPROBES|CONFIG_FTRACE_SYSCALLS|CONFIG_DYNAMIC_FTRACE|CONFIG_FUNCTION_TRACER|CONFIG_FANOTIFY|CONFIG_FANOTIFY_ACCESS_PERMISSIONS|CONFIG_KSU)' \
    "$DEFCONFIG.orig" > "$DEFCONFIG"
grep -vE '^\s*#' "$FRAGMENT" | grep -vE '^\s*$' >> "$DEFCONFIG"
echo "   fragment diterapkan; cadangan: $DEFCONFIG.orig"

say "selesai"
cat <<EOF
Tree siap di: $ROOT

Verifikasi cepat:
  grep -cE 'CONFIG_(FANOTIFY|FTRACE_SYSCALLS|KPROBES)=y' $DEFCONFIG   # harus 3
  ls fs/susfs.c include/linux/susfs.h                                  # harus ada

Build lewat CI (disarankan - tidak perlu toolchain lokal):
  dorong tree ini ke repo-mu, lalu jalankan workflow di .github/workflows/
EOF
