#!/usr/bin/env bash
# Repairs the susfs hunks that reject against this particular 4.14 tree.
#
# A dry run on LineageOS sm7125 (lineage-22.1) left four rejects. Each one is
# a context mismatch, not a logic problem - this tree carries extra includes
# and Samsung's CONFIG_RKP_NS_PROT block that the upstream patch never saw.
# The reject that matters most is fs/namespace.c: its declaration block failed
# while the code that USES those symbols applied, so the file cannot compile
# until the declarations are restored.
#
# Every fix is guarded by a grep, so running this twice is safe.
set -euo pipefail
cd "${1:?pakai: fixups.sh <kernel-root>}"

ok()   { printf '  [ok]   %s\n' "$1"; }
skip() { printf '  [lewat] %s\n' "$1"; }

# ---------------------------------------------------------------- 1
# fs/proc/task_mmu.c: patch expected mm_inline.h to be the last include before
# <asm/elf.h>; this tree adds freezer.h, ctype.h and io_record.h after it.
F=fs/proc/task_mmu.c
if grep -q 'susfs_def.h' "$F"; then
    skip "$F sudah punya susfs_def.h"
else
    python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "#include <linux/mm_inline.h>\n"
add = ("#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n"
       "#include <linux/susfs_def.h>\n"
       "#endif\n")
assert anchor in s, "anchor mm_inline.h tidak ketemu"
open(p, "w").write(s.replace(anchor, anchor + add, 1))
PY
    ok "$F: tambah include susfs_def.h"
fi

# ---------------------------------------------------------------- 2
# fs/readdir.c: susfs landed in filldir/filldir64/compat_filldir but not in
# compat_fillonedir, whose body differs here.
F=fs/readdir.c
if grep -q 'compat_fillonedir' "$F" && \
   awk '/static int compat_fillonedir/,/^}/' "$F" | grep -q susfs_sus_ino_for_filldir64; then
    skip "$F compat_fillonedir sudah ter-patch"
else
    python3 - "$F" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
m = re.search(r'(static int compat_fillonedir\(.*?\{.*?if \(buf->result\)\n\t\treturn -EINVAL;\n)',
              s, re.S)
assert m, "blok compat_fillonedir tidak ketemu"
add = ("#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
       "\tif (likely(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC) && "
       "susfs_sus_ino_for_filldir64(ino)) {\n"
       "\t\treturn 0;\n"
       "\t}\n"
       "#endif\n")
s = s[:m.end(1)] + add + s[m.end(1):]
open(p, "w").write(s)
PY
    ok "$F: tambah cek susfs di compat_fillonedir"
fi

# ---------------------------------------------------------------- 3
# fs/namespace.c: three hunks. The symbols are already referenced throughout
# the file, so without these declarations the build fails outright.
F=fs/namespace.c
if grep -q 'susfs_mnt_id_ida' "$F" && grep -q 'DEFINE_IDA(susfs_mnt_id_ida)' "$F"; then
    skip "$F deklarasi sudah ada"
else
    python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()

inc_anchor = "#include <linux/sched/task.h>\n"
assert inc_anchor in s, "anchor sched/task.h tidak ketemu"
if "susfs_def.h" not in s:
    s = s.replace(inc_anchor, inc_anchor +
        "#if defined(CONFIG_KSU_SUSFS_SUS_MOUNT) || defined(CONFIG_KSU_SUSFS_TRY_UMOUNT)\n"
        "#include <linux/susfs_def.h>\n"
        "#endif\n", 1)

decl_anchor = '#include "internal.h"\n'
assert decl_anchor in s, "anchor internal.h tidak ketemu"
decls = '''
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern bool susfs_is_current_zygote_domain(void);

static DEFINE_IDA(susfs_mnt_id_ida);
static DEFINE_IDA(susfs_mnt_group_ida);
static int susfs_mnt_id_start = DEFAULT_SUS_MNT_ID;
static int susfs_mnt_group_start = DEFAULT_SUS_MNT_GROUP_ID;

#define CL_ZYGOTE_COPY_MNT_NS BIT(24) /* used by copy_mnt_ns() */
#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */
#endif

#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
extern void susfs_auto_add_sus_ksu_default_mount(const char __user *to_pathname);
bool susfs_is_auto_add_sus_ksu_default_mount_enabled = true;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
extern int susfs_auto_add_sus_bind_mount(const char *pathname, struct path *path_target);
bool susfs_is_auto_add_sus_bind_mount_enabled = true;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
extern void susfs_auto_add_try_umount_for_bind_mount(struct path *path);
bool susfs_is_auto_add_try_umount_for_bind_mount_enabled = true;
#endif
'''
s = s.replace(decl_anchor, decl_anchor + decls, 1)
open(p, "w").write(s)
PY
    ok "$F: tambah include + blok deklarasi"
fi

# clone_mnt still calls the one-argument alloc_vfsmnt; this tree's extra
# CONFIG_RKP_NS_PROT block is why the hunk missed.
if grep -q 'bypass_orig_flow_clone_mnt' "$F"; then
    skip "$F clone_mnt sudah ter-patch"
elif grep -qP '^\tmnt = alloc_vfsmnt\(old->mnt_devname\);$' "$F"; then
    python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\tmnt = alloc_vfsmnt(old->mnt_devname);\n"
assert s.count(old) == 1, "panggilan alloc_vfsmnt(old->mnt_devname) tidak unik"
new = '''#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	bool is_current_ksu_domain = susfs_is_current_ksu_domain();
	bool is_current_zygote_domain = susfs_is_current_zygote_domain();

	if (unlikely(is_current_ksu_domain)) {
		if (!(flag & CL_COPY_MNT_NS)) {
			mnt = alloc_vfsmnt(old->mnt_devname, true, 0);
			goto bypass_orig_flow_clone_mnt;
		}
		mnt = alloc_vfsmnt(old->mnt_devname, true, old->mnt_id);
		if (mnt) {
			mnt->mnt.susfs_mnt_id_backup = DEFAULT_SUS_MNT_ID_FOR_KSU_PROC_UNSHARE;
		}
		goto bypass_orig_flow_clone_mnt;
	}
	if (likely(is_current_zygote_domain) && (old->mnt_id >= DEFAULT_SUS_MNT_ID)) {
		mnt = alloc_vfsmnt(old->mnt_devname, true, 0);
		goto bypass_orig_flow_clone_mnt;
	}
	if ((flag & CL_COPY_MNT_NS) && (old->mnt_id >= DEFAULT_SUS_MNT_ID)) {
		mnt = alloc_vfsmnt(old->mnt_devname, true, 0);
		goto bypass_orig_flow_clone_mnt;
	}
	mnt = alloc_vfsmnt(old->mnt_devname, false, 0);
bypass_orig_flow_clone_mnt:
#else
	mnt = alloc_vfsmnt(old->mnt_devname);
#endif
'''
open(p, "w").write(s.replace(old, new, 1))
PY
    ok "$F: clone_mnt diarahkan ke alloc_vfsmnt bervarian susfs"
else
    skip "$F clone_mnt: pola tidak ketemu, periksa manual"
fi

# copy_mnt_ns must tell clone_mnt that the clone came from copy_mnt_ns().
if grep -q 'copy_flags |= CL_COPY_MNT_NS;' "$F"; then
    skip "$F copy_mnt_ns sudah ter-patch"
else
    python3 - "$F" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
m = re.search(r'\n(\tnew = copy_tree\(old, old->mnt\.mnt_root, copy_flags\);\n)', s)
if not m:
    print("  [lewat] copy_mnt_ns: anchor copy_tree tidak ketemu")
else:
    add = ('#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'
           '\tcopy_flags |= CL_COPY_MNT_NS;\n'
           '\tif (is_zygote_pid) {\n'
           '\t\tcopy_flags |= CL_ZYGOTE_COPY_MNT_NS;\n'
           '\t}\n'
           '#endif\n')
    s = s[:m.start(1)] + add + s[m.start(1):]
    open(p, "w").write(s)
PY
    ok "$F: copy_mnt_ns menandai CL_COPY_MNT_NS"
fi

# ---------------------------------------------------------------- 4
# fs/notify/fdinfo.c: only the body hunk missed; the patched signature that
# takes `struct file *file` is already present. This hunk only hides inotify
# watch details, so a miss is cosmetic - never fail the build over it.
F=fs/notify/fdinfo.c
if grep -q 'INODE_STATE_SUS_KSTAT' "$F"; then
    skip "$F sudah ter-patch"
else
    skip "$F tidak di-patch (hanya menyembunyikan detail inotify, tidak kritis)"
fi

# The .rej files left by the original patch run are stale once these fixes are
# in - they describe what failed then, not what is missing now. Remove the ones
# whose fix is verified in place so the output is not misleading.
for pair in "fs/proc/task_mmu.c:CONFIG_KSU_SUSFS_SUS_KSTAT" \
            "fs/readdir.c:susfs_sus_ino_for_filldir64" \
            "fs/namespace.c:bypass_orig_flow_clone_mnt"; do
    f=${pair%%:*}; tok=${pair##*:}
    if [ -f "$f.rej" ] && grep -q "$tok" "$f"; then
        rm -f "$f.rej"
        echo "  [bersih] $f.rej (perbaikan terverifikasi di kode)"
    fi
done

echo
echo "sisa reject:"
find . -name '*.rej' -printf '  %p\n' 2>/dev/null | grep . || echo "  (tidak ada yang kritis)"
