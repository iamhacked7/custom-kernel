# a52q diagnostic kernel

Kernel untuk Samsung Galaxy A52 4G (SM-A525F, `a52q`, SM7125 "atoll").

**Tujuan utama: diagnosis.** Kernel stock A52 tidak mengompilasi satu pun alat
pelacakan, sehingga mustahil melihat apa yang sebenarnya diperiksa oleh RASP
seperti Garuda Defender:

| Metode | Di kernel stock |
|---|---|
| `fanotify` | `ENOSYS` — `CONFIG_FANOTIFY` tidak ada |
| ftrace syscall | `events/syscalls` tidak ada, `available_tracers` = `nop` |
| sampling `/proc/<tid>/syscall` | 0 tangkapan dari ribuan syscall |
| `ptrace`/`strace` | terpicu anti-debug, proses dibunuh |

Build ini menyalakan `CONFIG_FANOTIFY`, `CONFIG_FTRACE_SYSCALLS`, dan
`CONFIG_KPROBES` — ketiganya bekerja **di sisi kernel**, jadi aplikasi tidak
punya apa pun untuk dideteksi.

## Komponen

- Basis: [LineageOS/android_kernel_samsung_sm7125](https://github.com/LineageOS/android_kernel_samsung_sm7125) (`lineage-22.1`, `lineage-a52q_defconfig`)
- Root: [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) v3.4.2
- Hiding: [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) cabang `kernel-4.14` (v1.5.5)

## Catatan mode hook

Hook KernelSU memakai **manual hook**, bukan tracepoint/kprobe. Itu syarat dari
README susfs4ksu sendiri untuk non-GKI:

> Replace all lines starting with `#ifdef CONFIG_KPROBES` to
> `#if defined(CONFIG_KPROBES) && 0` ... this is to tell KernelSU not to use
> any kprobe hooks.

`CONFIG_KPROBES=y` tetap dinyalakan, tapi untuk infrastruktur pelacakan kita —
bukan untuk hook KSU. Keduanya tidak bertabrakan. `setup.sh` menerapkan langkah
susfs itu otomatis.

SUSFS v1.5.5 adalah versi **terbaru yang tersedia** untuk kernel 4.14: cabang
`kernel-4.14` beku sejak 2025-02-23, dan v1.5.9+ hanya ada di cabang GKI.

## Cara build

Actions → **Build a52q — KSU-Next + SUSFS + Diagnostics** → *Run workflow*.
Hasilnya di artifact `a52q-Image-KSUNext-SUSFS-diag`.

Workflow berhenti dengan error kalau salah satu flag diagnosis tidak benar-benar
masuk ke defconfig — jadi tidak mungkin menghasilkan kernel yang diam-diam tanpa
alat pelacakan.

## Setelah terpasang

Jalankan `trace_detections.sh` sebagai root di perangkat.
