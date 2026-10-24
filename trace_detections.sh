#!/system/bin/sh
# Jalankan ini SETELAH kernel baru terpasang.
#
# Inilah alasan kernel itu dibangun. Pada kernel stock A52 semua jalur
# pelacakan tertutup: fanotify -> ENOSYS, events/syscalls tidak ada,
# available_tracers cuma "nop", sampling /proc/<tid>/syscall menangkap 0 dari
# ribuan syscall, dan ptrace langsung memicu anti-debug sehingga proses mati.
# Dengan CONFIG_FTRACE_SYSCALLS + CONFIG_FANOTIFY, kernel sendiri yang
# melaporkan - aplikasi tidak punya apa pun untuk dideteksi.
PKG=com.kikyps.crackme
T=/sys/kernel/tracing
OUT=/data/local/tmp/gd-trace
mkdir -p $OUT

[ -d "$T/events/syscalls" ] || {
    echo "!! $T/events/syscalls tidak ada."
    echo "   Kernel ini belum punya CONFIG_FTRACE_SYSCALLS=y - build belum terpasang."
    exit 1
}

echo "== siapkan tracer =="
echo 0 > $T/tracing_on
echo > $T/trace
echo 1 > $T/options/record-tgid 2>/dev/null

# Hanya syscall yang membawa nama berkas / tujuan koneksi / argumen menarik.
for e in sys_enter_openat sys_enter_newfstatat sys_enter_faccessat \
         sys_enter_readlinkat sys_enter_statx sys_enter_connect \
         sys_enter_prctl sys_enter_ptrace sys_enter_getdents64; do
    [ -d "$T/events/syscalls/$e" ] && echo 1 > $T/events/syscalls/$e/enable
done

am force-stop $PKG 2>/dev/null
sleep 1
echo 1 > $T/tracing_on
am start -n $PKG/$PKG.MainActivity >/dev/null 2>&1

# Catat pid secepat mungkin, lalu persempit trace ke pid itu saja.
i=0
while [ $i -lt 600 ]; do
    PID=$(pidof $PKG)
    [ -n "$PID" ] && break
    i=$((i+1))
done
[ -n "$PID" ] && echo "$PID" > $T/set_event_pid 2>/dev/null
echo "pid=$PID"

sleep 25
echo 0 > $T/tracing_on
cp $T/trace $OUT/raw.txt
echo "baris trace: $(wc -l < $OUT/raw.txt)"

echo
echo "== PATH yang benar-benar dibuka/diperiksa =="
grep -oE '"[^"]+"' $OUT/raw.txt | tr -d '"' | grep '^/' | sort -u | tee $OUT/paths.txt | head -60

echo
echo "== jejak root/hiding di antaranya =="
grep -iE 'su$|/su/|magisk|ksu|zygisk|susfs|xposed|lsposed|riru|supolicy|busybox|adb|frida|gum|memfd|modules|osrelease|selinux' $OUT/paths.txt | head -40

echo
echo "== prctl (magic KernelSU dicek?) =="
grep -a 'sys_enter_prctl' $OUT/raw.txt | sed -E 's/.*prctl\(//' | sort -u | head -15

echo
echo "== connect (probe port) =="
grep -a 'sys_enter_connect' $OUT/raw.txt | head -10

echo
echo "hasil lengkap: $OUT/raw.txt, $OUT/paths.txt"
