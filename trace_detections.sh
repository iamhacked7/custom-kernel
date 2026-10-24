#!/system/bin/sh
# Jalankan sebagai root SETELAH kernel baru terpasang.
#
# Inilah alasan kernel itu dibangun. Pada kernel stock A52 semua jalur
# pelacakan tertutup: fanotify -> ENOSYS, events/syscalls tidak ada,
# available_tracers cuma "nop", sampling /proc/<tid>/syscall menangkap 0 dari
# ribuan syscall, dan ptrace langsung memicu anti-debug sehingga proses mati.
#
# Semua pelacakan di sini berjalan DI SISI KERNEL. Tidak ada ptrace, tidak ada
# kode yang disuntik ke proses, tidak ada library tambahan - jadi anti-debug
# dan anti-instrumentation aplikasi tidak punya apa pun untuk dideteksi. Itu
# sebabnya ini berhasil di tempat Frida selalu dibunuh dalam 0,2 detik.
PKG=com.kikyps.crackme
T=/sys/kernel/tracing
[ -d "$T" ] || T=/sys/kernel/debug/tracing
OUT=/data/local/tmp/gd-trace
mkdir -p $OUT

need() {
    [ -e "$1" ] && return 0
    echo "!! tidak ada: $1"
    echo "   -> $2"
    return 1
}
need "$T/events/syscalls" "kernel ini belum CONFIG_FTRACE_SYSCALLS=y" || exit 1

echo "== kemampuan kernel =="
printf "  syscall events : %s\n" "$([ -d $T/events/syscalls ] && echo ADA || echo '-')"
printf "  uprobe events  : %s\n" "$([ -e $T/uprobe_events ] && echo ADA || echo '-')"
printf "  kprobe events  : %s\n" "$([ -e $T/kprobe_events ] && echo ADA || echo '-')"
printf "  tracers        : %s\n" "$(cat $T/available_tracers 2>/dev/null)"

# ---------------------------------------------------------------- reset
echo 0 > $T/tracing_on
echo    > $T/trace
echo    > $T/uprobe_events 2>/dev/null
echo    > $T/kprobe_events 2>/dev/null
echo 1 > $T/options/record-tgid 2>/dev/null
for d in $T/events/*/*/enable; do echo 0 > "$d" 2>/dev/null; done

# ------------------------------------------------- 1. syscall berargumen
# Hanya yang membawa nama berkas, tujuan koneksi, atau argumen bermakna.
for e in sys_enter_openat sys_enter_newfstatat sys_enter_faccessat \
         sys_enter_readlinkat sys_enter_statx sys_enter_getdents64 \
         sys_enter_connect sys_enter_socket \
         sys_enter_prctl sys_enter_ptrace sys_enter_process_vm_readv; do
    [ -d "$T/events/syscalls/$e" ] && echo 1 > "$T/events/syscalls/$e/enable"
done

# ------------------------------------------------------------ 2. uprobe
# INI yang menutup celah terbesar: dl_iterate_phdr menelusuri link_map di
# dalam memori proses TANPA syscall, jadi tak terlihat oleh tracing syscall.
# Uprobe memasangnya dari sisi kernel.
LINKER=/apex/com.android.runtime/bin/linker64
[ -f "$LINKER" ] || LINKER=/system/bin/linker64
LIBC=/apex/com.android.runtime/lib64/bionic/libc.so
[ -f "$LIBC" ] || LIBC=/system/lib64/libc.so

add_uprobe() {   # nama  berkas  simbol
    off=$(nm -D --defined-only "$2" 2>/dev/null | awk -v s="$3" '$3==s{print $1; exit}')
    [ -z "$off" ] && { echo "  - $3: simbol tidak ketemu di $(basename $2)"; return; }
    if echo "p:$1 $2:0x$off" >> $T/uprobe_events 2>/dev/null; then
        echo 1 > "$T/events/uprobes/$1/enable" 2>/dev/null
        echo "  + $3 @ $(basename $2)+0x$off"
    else
        echo "  - $3: gagal dipasang"
    fi
}
if [ -e "$T/uprobe_events" ]; then
    echo "== pasang uprobe =="
    add_uprobe u_dlph   "$LINKER" dl_iterate_phdr
    add_uprobe u_dlopen "$LINKER" __loader_dlopen
    add_uprobe u_prop   "$LIBC"   __system_property_get
else
    echo "!! uprobe_events tidak ada - CONFIG_UPROBE_EVENTS belum aktif."
    echo "   dl_iterate_phdr TIDAK akan terlihat tanpa ini."
fi

# ---------------------------------------------------------------- jalan
am force-stop $PKG 2>/dev/null
sleep 1
echo 1 > $T/tracing_on
am start -n $PKG/$PKG.MainActivity >/dev/null 2>&1

i=0
while [ $i -lt 800 ]; do PID=$(pidof $PKG); [ -n "$PID" ] && break; i=$((i+1)); done
[ -n "$PID" ] && echo "$PID" > $T/set_event_pid 2>/dev/null
echo "pid=$PID — merekam 25 detik"
sleep 25
echo 0 > $T/tracing_on
cp $T/trace $OUT/raw.txt
echo "baris trace: $(wc -l < $OUT/raw.txt)"

# ---------------------------------------------------------------- hasil
echo
echo "===== PATH yang diperiksa ====="
grep -oE '"[^"]+"' $OUT/raw.txt | tr -d '"' | grep '^/' | sort -u > $OUT/paths.txt
wc -l < $OUT/paths.txt | sed 's/^/  total unik: /'
head -50 $OUT/paths.txt

echo
echo "===== jejak root / hiding di antaranya ====="
grep -iE '(^|/)su$|/su/|magisk|ksu|zygisk|susfs|xposed|lsposed|riru|supolicy|busybox|frida|gum|memfd|/proc/modules|osrelease|selinux|adb' \
    $OUT/paths.txt | tee $OUT/root_hits.txt | head -40

echo
echo "===== dl_iterate_phdr dipanggil? (celah utama) ====="
grep -ac 'u_dlph' $OUT/raw.txt | sed 's/^/  panggilan: /'

echo
echo "===== properti sistem yang dibaca ====="
grep -a 'u_prop' $OUT/raw.txt | wc -l | sed 's/^/  panggilan __system_property_get: /'

echo
echo "===== prctl (magic KernelSU dicek?) ====="
grep -a 'sys_enter_prctl' $OUT/raw.txt | sed -E 's/.*prctl\(//' | sort -u | head -15

echo
echo "===== connect / socket (probe port) ====="
grep -aE 'sys_enter_(connect|socket)' $OUT/raw.txt | head -10

echo
echo "berkas: $OUT/raw.txt  $OUT/paths.txt  $OUT/root_hits.txt"
