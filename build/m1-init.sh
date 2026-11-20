#!/bin/busybox sh
# QEMU arm64_virt M1 init for HarmonyOS 7.0.0.107 (Pura 70 Pro+ donor userland on Linux 6.6).
# Mounts read-only EROFS donor partitions + qemu_overlay + writable userdata, sets up binderfs,
# access_token_id, SLIRP networking, and hands PID 1 to /system/bin/init --second-stage.

/bin/busybox --install -s /bin
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mkdir -p /proc /sys /dev /tmp /run /hmos /qoverlay /data /hmos-root /hmos-ram
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs -o mode=0755 devtmpfs /dev || mount -t tmpfs -o mode=0755 dev /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs tmp /tmp
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
echo /bin/mdev > /proc/sys/kernel/hotplug 2>/dev/null || true
mdev -s

log() {
    echo "hmos7-qemu-m1: $*" > /dev/kmsg 2>/dev/null || true
    echo "hmos7-qemu-m1: $*"
}

hold() {
    log "HOLD: $*"
    exec /bin/sh -l
}

log "init started on $(uname -a)"

# Load out-of-tree HarmonyOS helper kernel modules (kstate netlink 30 + hwlog + ashmem)
for mod in /lib/modules/kstate.ko /lib/modules/hwlog.ko /lib/modules/ashmem.ko; do
    if [ -f "$mod" ]; then
        insmod "$mod" 2>&1 | while read -r l; do log "insmod $(basename $mod): $l"; done
    fi
done
mdev -s

# Bring up networking:
# - Dual-NIC mode (socket_vmnet bridged/shared): eth0 is the real L2 Ethernet NIC managed by
#   HarmonyOS EthernetManager + dhcp_client (SA 1126); eth1 is renamed to hdc0 (restrict=on,
#   loopback-only hdc management channel with NO default route and NO NAT).
# - Single-NIC fallback (HMOS7_NET=user): eth0 is brought up for EthernetManager DHCP while
#   also receiving 10.0.2.15/24 immediately so hdcd is reachable before DHCP completes.
ip link set lo up 2>/dev/null || true
if ip link show eth1 >/dev/null 2>&1; then
    ip link set eth0 up
    ip link set eth1 down 2>/dev/null || true
    ip link set eth1 name hdc0 2>/dev/null || true
    ip link set hdc0 up 2>/dev/null || true
    ip addr add 10.0.2.15/24 dev hdc0 2>/dev/null || true
    log "dual-NIC ready: eth0 (UP, DHCP via EthernetManager) + hdc0 (10.0.2.15/24, loopback hdc only)"
elif ip link show eth0 >/dev/null 2>&1; then
    ip link set eth0 up
    ip addr add 10.0.2.15/24 dev eth0 2>/dev/null || true
    ip route add default via 10.0.2.2 dev eth0 2>/dev/null || true
    log "single-NIC fallback: eth0 UP (DHCP via EthernetManager + initial 10.0.2.15/24)"
fi

# Start a diagnostic root shell on virtio-console hvc0 (if attached) so host can inspect even if init hangs.
if [ -c /dev/hvc0 ]; then
    setsid sh -c 'while true; do /bin/sh -l </dev/hvc0 >/dev/hvc0 2>&1; sleep 1; done' </dev/null >/dev/null 2>&1 &
    log "diagnostic shell attached on /dev/hvc0"
fi

# Wait for virtio-blk devices (vda..vdg)
i=0
while [ ! -b /dev/vdg ] && [ $i -lt 20 ]; do
    sleep 1
    mdev -s
    i=$((i + 1))
done

# Mount read-only donor EROFS partitions:
# vda=system, vdb=vendor, vdc=sys_prod, vdd=chip_prod, vde=cust
mount_ro() {
    dev=$1; name=$2; fstype=$3
    mkdir -p "/hmos/$name"
    mount -t "$fstype" -o ro "/dev/$dev" "/hmos/$name" || hold "failed to mount /dev/$dev ($name, $fstype)"
}
mount_ro vda system erofs
mount_ro vdb vendor erofs
mount_ro vdc sys_prod erofs
mount_ro vdd chip_prod erofs
mount_ro vde cust erofs

# Mount our read-only QEMU overlay partition (vdf)
mount -t ext4 -o ro /dev/vdf /qoverlay || hold "failed to mount /dev/vdf (qoverlay)"
log "mounted donor EROFS partitions + qoverlay"

# Mount writable userdata (vdg); only format ext4 if mount fails and first 8 KiB are all zeros
if ! mount -t ext4 -o noatime /dev/vdg /data 2>/dev/null; then
    if [ "$(dd if=/dev/vdg bs=4096 count=2 2>/dev/null | tr -d '\000' | wc -c)" -eq 0 ]; then
        log "userdata (/dev/vdg) is blank; formatting ext4 using donor mke2fs"
        mount --bind /dev /hmos/system/dev && mount -t proc proc /hmos/system/proc
        chroot /hmos/system /system/bin/mke2fs -t ext4 -b 4096 -L userdata /dev/vdg >/tmp/mke2fs.log 2>&1 || \
            log "mke2fs error: $(tail -n 3 /tmp/mke2fs.log)"
        umount /hmos/system/proc /hmos/system/dev 2>/dev/null || true
    fi
    mount -t ext4 -o noatime /dev/vdg /data || hold "failed to mount /dev/vdg (/data)"
fi
log "mounted /data (ext4)"

# Assemble /hmos-root using overlayfs over donor system + bind mounts
ROOT=/hmos-root
mount -t tmpfs -o mode=0755,size=1536m hmos-ram /hmos-ram
mkdir -p /hmos-ram/upper /hmos-ram/work
mount -t overlay -o lowerdir=/hmos/system,upperdir=/hmos-ram/upper,workdir=/hmos-ram/work overlay "$ROOT" || \
    hold "overlayfs on $ROOT failed"

for p in vendor sys_prod chip_prod cust; do
    mkdir -p "$ROOT/$p"
    mount --bind "/hmos/$p" "$ROOT/$p"
done

mount --bind /data "$ROOT/data"
for d in metadata log mnt storage tmp; do
    mkdir -p "$ROOT/$d"
    mount -t tmpfs -o mode=0755,size=128m "hmos-$d" "$ROOT/$d"
done

for d in dev/__parameters__ data/service/el0/startup/init data/service/el1/startup/parameters \
         data/local/tmp data/service/el1/public data/app/el1 data/storage/el1 data/storage/el2 \
         data/data data/log data/samgr; do
    mkdir -p "$ROOT/$d"
done

for d in dev proc sys; do
    mkdir -p "$ROOT/$d"
    mount --rbind "/$d" "$ROOT/$d"
done

# Setup binderfs and world-accessible binder + access_token_id nodes
mkdir -p "$ROOT/dev/binderfs"
if mount -t binder binder "$ROOT/dev/binderfs" 2>/dev/null; then
    for b in binder hwbinder vndbinder; do
        [ -e "$ROOT/dev/binderfs/$b" ] && chmod 0666 "$ROOT/dev/binderfs/$b" && ln -sf "binderfs/$b" "$ROOT/dev/$b"
    done
    log "binderfs mounted and 0666"
else
    for b in binder hwbinder vndbinder; do
        [ -e "$ROOT/dev/$b" ] && chmod 0666 "$ROOT/dev/$b"
    done
    log "using static /dev/binder nodes"
fi
[ -c "$ROOT/dev/access_token_id" ] && chmod 0666 "$ROOT/dev/access_token_id" || log "WARN: /dev/access_token_id missing"
[ -c "$ROOT/dev/ashmem" ] && chmod 0666 "$ROOT/dev/ashmem" || log "WARN: /dev/ashmem missing"
[ -c "$ROOT/dev/tun" ] && chmod 0666 "$ROOT/dev/tun" || true
[ -c "$ROOT/dev/net/tun" ] && chmod 0666 "$ROOT/dev/net/tun" || true
if [ ! -e "$ROOT/dev/tun" ] && [ -e "$ROOT/dev/net/tun" ]; then
    ln -sf net/tun "$ROOT/dev/tun"
fi
mkdir -p "$ROOT/sys/fs/selinux"
mount -t selinuxfs selinuxfs "$ROOT/sys/fs/selinux" 2>/dev/null || true

# Mount cgroup v1 controllers expected by OHOS init/services
mkdir -p "$ROOT/dev/cpuset" "$ROOT/dev/memcg" "$ROOT/dev/pids" "$ROOT/dev/frz" "$ROOT/dev/cpuctl" "$ROOT/dev/blkio"
mount -t cgroup -o cpuset cpuset "$ROOT/dev/cpuset" 2>/dev/null || true
mount -t cgroup -o memory memory "$ROOT/dev/memcg" 2>/dev/null || true
mount -t cgroup -o pids pids "$ROOT/dev/pids" 2>/dev/null || true
mount -t cgroup -o freezer freezer "$ROOT/dev/frz" 2>/dev/null || true
mount -t cgroup -o cpu,cpuacct cpu "$ROOT/dev/cpuctl" 2>/dev/null || true
mkdir -p "$ROOT/dev/memcg/perf_sensitive" "$ROOT/dev/cpuset/foreground" "$ROOT/dev/cpuset/background" 2>/dev/null || true

# Replace all init service dirs with tmpfs and install ONLY our curated QEMU service set
for d in system/etc/init sys_prod/etc/init chip_prod/etc/init vendor/etc/init cust/etc/init; do
    [ -d "$ROOT/$d" ] && mount -t tmpfs -o mode=0755,size=4m hmos-init "$ROOT/$d"
done
if [ -d /qoverlay/init ]; then
    cp /qoverlay/init/*.cfg "$ROOT/system/etc/init/"
    log "installed $(ls $ROOT/system/etc/init/*.cfg | wc -l) init configs"
fi

# Bind /qoverlay into $ROOT/qoverlay so HarmonyOS init helper services can invoke scripts/busybox
mkdir -p "$ROOT/qoverlay"
mount --bind /qoverlay "$ROOT/qoverlay"

# Bind HarmonyOS-friendly /proc/cmdline (ohos.boot.hardware=virt, enforcing=0)
EXTRA="ohos.boot.hardware=virt ohos.boot.selinux=permissive enforcing=0"
echo "$(cat /proc/cmdline) $EXTRA" > /hmos-ram/cmdline
mount --bind /hmos-ram/cmdline "$ROOT/proc/cmdline"

# Run overlay prep script if present
if [ -f /qoverlay/boot/prep.sh ]; then
    sh /qoverlay/boot/prep.sh "$ROOT" 2>&1 | while read -r l; do log "prep: $l"; done
fi

if grep -q "hmos.hold=1" /proc/cmdline; then
    hold "hmos.hold=1 requested; root assembled at $ROOT"
fi

[ -x "$ROOT/system/bin/init" ] || hold "no $ROOT/system/bin/init"

# Bind $ROOT onto / so HarmonyOS init setns sandbox stays inside $ROOT
mount --rbind "$ROOT" / || hold "could not bind $ROOT onto /"
log "handing PID 1 to HarmonyOS 7 /system/bin/init --second-stage"
cd "$ROOT"
exec chroot "$ROOT" /system/bin/init --second-stage
hold "exec /system/bin/init failed"
