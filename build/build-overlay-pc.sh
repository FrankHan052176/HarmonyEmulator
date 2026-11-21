#!/bin/bash
# Builds HarmonyOS PC (MateBook Pro HAD-W32 207.0.0.107 SP7) qemu_overlay_pc.img inside Lima.
set -euo pipefail

HMOS_BASE="${HMOS7_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO="${HMOS7_ASTEROIDS_REPO:-$HMOS_BASE/refs/hmos-asteroids}"
DONORDIR="$REPO/donor/pura70proplus-7.0.0.107"
DONOR="${HMOS7_PC_DONOR_MNT:-/tmp/pc-mnt}"
OHOSREF="${HMOS7_OHOS_REF:-/tmp/ohos-ref}"
NATIVE="${HMOS7_NATIVE_DIR:-$HMOS_BASE/build/m2-native}"
SIGN_DIR="${HMOS7_SIGN_DIR:-$HMOS_BASE/signing}"
OUT="${HMOS7_PC_OVERLAY_OUT:-$HMOS_BASE/out/qemu_overlay_pc.img}"
STAGE="/tmp/hmos7-pc-stage"

rm -rf "$STAGE"
mkdir -p "$STAGE"/{bin,boot,etc/security,init,system/bin,system/lib64/chipset-sdk,system/lib64/platformsdk,system/profile,vendor/lib64/passthrough/indirect,vendor/etc/param}

echo "=== 1. Busybox & helper binaries ==="
cp /bin/busybox "$STAGE/bin/busybox"
chmod 0755 "$STAGE/bin/busybox"
cp "$NATIVE/bin/tap" "$STAGE/bin/tap"
cp "$NATIVE/system/bin/render_service_launcher" "$STAGE/system/bin/"
cp "$NATIVE/system/bin/capture_scanout" "$STAGE/system/bin/"
chmod 0755 "$STAGE/bin/tap" "$STAGE/system/bin/render_service_launcher" "$STAGE/system/bin/capture_scanout"

echo "=== 2. Native VDIs, SwiftShader Vulkan ICD (v210 + v200), HUKS, UserIAM, framework shims ==="
cp "$NATIVE/vendor/lib64/libdisplay_composer_vdi_impl.z.so" "$STAGE/vendor/lib64/"
cp "$NATIVE/vendor/lib64/libsheng_userauth_4_0.so" "$STAGE/vendor/lib64/"
cp "$NATIVE/vendor/lib64/libuser_auth_interface_service_4.1.z.so" "$STAGE/vendor/lib64/"
cp "$NATIVE/vendor/lib64/libuser_auth_driver.z.so" "$STAGE/vendor/lib64/"
cp "$NATIVE/vendor/lib64/passthrough/vulkan.hvgr_v200.so" "$STAGE/vendor/lib64/passthrough/vulkan.hvgr_v210.so"
cp "$NATIVE/vendor/lib64/passthrough/vulkan.hvgr_v200.so" "$STAGE/vendor/lib64/passthrough/vulkan.hvgr_v200.so"
cp "$NATIVE/vendor/lib64/passthrough/indirect/libdisplay_buffer_vdi_impl.z.so" "$STAGE/vendor/lib64/passthrough/indirect/"
cp "$NATIVE/vendor/lib64/passthrough/indirect/libhuks_ca_hdi.z.so" "$STAGE/vendor/lib64/passthrough/indirect/"
cp "$NATIVE/system/lib64/"*.so "$STAGE/system/lib64/"

echo "=== 3. Prebuilt ohos-qemu SwiftShader + Mesa GLES/swrast + libdrm ==="
sudo cp "$OHOSREF/system/system/lib64/libvk_swiftshader.so" "$STAGE/vendor/lib64/passthrough/libvk_swiftshader.so"
sudo cp "$OHOSREF/system/system/lib64/chipset-sdk/libdrm.so" "$STAGE/vendor/lib64/libdrm.so"
sudo cp "$OHOSREF/system/system/lib64/chipset-sdk/libdrm.so" "$STAGE/vendor/lib64/chipset-sdk/libdrm.so" 2>/dev/null || true
mkdir -p "$STAGE/vendor/lib64/chipset-sdk"
sudo cp "$OHOSREF/system/system/lib64/chipset-sdk/libdrm.so" "$STAGE/vendor/lib64/chipset-sdk/libdrm.so"
sudo cp "$OHOSREF/system/system/lib64/chipset-sdk/libdrm.so" "$STAGE/system/lib64/chipset-sdk/libdrm.so"
sudo cp "$OHOSREF/system/system/lib64/libEGL_impl.so" "$STAGE/vendor/lib64/passthrough/libEGL_impl.so"
sudo cp "$OHOSREF/system/system/lib64/libGLESv1_impl.so" "$STAGE/vendor/lib64/passthrough/libGLESv1_impl.so"
sudo cp "$OHOSREF/system/system/lib64/libGLESv2_impl.so" "$STAGE/vendor/lib64/passthrough/libGLESv2_impl.so"
sudo cp "$OHOSREF/system/system/lib64/libGLESv3_impl.so" "$STAGE/vendor/lib64/passthrough/libGLESv3_impl.so"
sudo cp "$OHOSREF/system/system/lib64/libglapi.so.0.0.0" "$STAGE/system/lib64/libglapi.so.0.0.0"
ln -sf libglapi.so.0.0.0 "$STAGE/system/lib64/libglapi.so.0"
ln -sf libglapi.so.0.0.0 "$STAGE/system/lib64/libglapi.so"
sudo cp "$OHOSREF/system/system/lib64/libglapi.so.0.0.0" "$STAGE/vendor/lib64/libglapi.so.0.0.0"
ln -sf libglapi.so.0.0.0 "$STAGE/vendor/lib64/libglapi.so.0"
sudo cp "$OHOSREF/system/system/lib64/kms_swrast_dri.so" "$STAGE/system/lib64/kms_swrast_dri.so"
ln -sf kms_swrast_dri.so "$STAGE/system/lib64/swrast_dri.so"
ln -sf kms_swrast_dri.so "$STAGE/system/lib64/virtio_gpu_dri.so"
ln -sf /system/lib64/kms_swrast_dri.so "$STAGE/vendor/lib64/kms_swrast_dri.so"
ln -sf /system/lib64/kms_swrast_dri.so "$STAGE/vendor/lib64/swrast_dri.so"
sudo chown -R "$(id -u):$(id -g)" "$STAGE"

echo "=== 4. PC donor binary patches (dbkeys + composer_service_1.5) ==="
WORK=/tmp/hmos7-pc-patchwork
rm -rf "$WORK" && mkdir -p "$WORK"

while read -r lib prefix names; do
    sudo cat "$DONOR/system/system/lib64/$lib" > "$WORK/$lib.donor"
    python3 "$DONORDIR/patches/patch-huks-imports.py" "$WORK/$lib.donor" "$STAGE/system/lib64/$lib" "$prefix" $names
done <<'LIBS'
librelational_store_crypt.z.so S Abort Finish GenerateKey GenerateRandom Init KeyExist Update
libkv_store_crypt.z.so S Decrypt Encrypt GenerateKey GenerateRandom KeyExist
libdistributeddatasvcfwk.z.so D Decrypt Encrypt GenerateKey GenerateRandom KeyExist
LIBS

# PC libcode_sign_utils.z.so (MateBook Pro 207.0.0.107 SP7): skip fs-verity check (-770 -> 0)
sudo cat "$DONOR/system/system/lib64/libcode_sign_utils.z.so" > "$WORK/libcode_sign_utils.z.so.donor"
python3 - "$WORK/libcode_sign_utils.z.so.donor" "$STAGE/system/lib64/libcode_sign_utils.z.so" <<'PY'
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
off, old, new = 0x16ee4, 0x12806028, 0x52800008  # mov w8, #-770 -> mov w8, #0 (after tst w8, #0x10)
cur = struct.unpack_from("<I", data, off)[0]
assert cur in (old, new), f"libcode_sign_utils unexpected insn {cur:#x} at {off:#x}"
struct.pack_into("<I", data, off, new)
open(sys.argv[2], "wb").write(data)
print(f"{sys.argv[2]}: patched fs-verity check at {off:#x}")
PY

# PC libkey_enable.z.so (MateBook Pro 207.0.0.107 SP7): EnableKeyInProfileByRust -> mov w0,#0; ret
sudo cat "$DONOR/system/system/lib64/libkey_enable.z.so" > "$WORK/libkey_enable.z.so.donor"
python3 - "$WORK/libkey_enable.z.so.donor" "$STAGE/system/lib64/libkey_enable.z.so" <<'PY'
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
off = 0x11e94  # EnableKeyInProfileByRust (VA 0x12e94, delta 0x1000)
struct.pack_into("<I", data, off, 0x52800000)      # mov w0, #0
struct.pack_into("<I", data, off + 4, 0xd65f03c0)  # ret
open(sys.argv[2], "wb").write(data)
print(f"{sys.argv[2]}: patched EnableKeyInProfileByRust at {off:#x}")
PY

# PC libaccountmgr.z.so (MateBook Pro 207.0.0.107 SP7): stub OsAccountTeeAdapter::Impl TEE calls
# so GetOsAccountType(id=100) returns ADMIN (0) in 0ms instead of blocking 115s on SA 8001 (tee_client).
sudo cat "$DONOR/system/system/lib64/libaccountmgr.z.so" > "$WORK/libaccountmgr.z.so.donor"
python3 - "$WORK/libaccountmgr.z.so.donor" "$STAGE/system/lib64/libaccountmgr.z.so" <<'PY'
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
# GetOsAccountType(this, int id, int &type) at VA 0x153844 (file offset 0x152844):
#   str wzr, [x2]; mov w0, #0; ret
off = 0x152844
struct.pack_into("<III", data, off, 0xb900005f, 0x52800000, 0xd65f03c0)
# SetOsAccountType (x2), MigrateOsAccountTypesToTee, DelOsAccountType -> mov w0, #0; ret
for off in (0x152a84, 0x152c2c, 0x152ef4, 0x1533b8):
    struct.pack_into("<II", data, off, 0x52800000, 0xd65f03c0)
open(sys.argv[2], "wb").write(data)
print(f"{sys.argv[2]}: stubbed OsAccountTeeAdapter::Impl TEE calls (ADMIN=0, ERR_OK=0)")
PY

# PC platformsdk/libaudio_policy_client.z.so: switch GetSystemAbility(3009) slot +32 -> CheckSystemAbility slot +40
# so SceneBoard's UI thread never blocks 1.2s per call (which triggered THREAD_BLOCK_3S AppFreeze).
sudo cat "$DONOR/system/system/lib64/platformsdk/libaudio_policy_client.z.so" > "$WORK/libaudio_policy_client.z.so.donor"
python3 - "$WORK/libaudio_policy_client.z.so.donor" "$STAGE/system/lib64/platformsdk/libaudio_policy_client.z.so" <<'PY'
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
for off in (0x3a808, 0x787a8):  # VA 0x3b808 & 0x797a8 (delta 0x1000): ldr x9,[x8,#32] -> ldr x9,[x8,#40]
    cur = struct.unpack_from("<I", data, off)[0]
    assert cur in (0xf9401109, 0xf9401509), f"unexpected insn {cur:#x} at {off:#x}"
    struct.pack_into("<I", data, off, 0xf9401509)
open(sys.argv[2], "wb").write(data)
print(f"{sys.argv[2]}: patched GetSystemAbility(3009) -> CheckSystemAbility at 0x3a808 & 0x787a8")
PY

sudo cat "$DONOR/vendor/lib64/libdisplay_composer_service_1.5.z.so" > "$WORK/libdisplay_composer_service_1.5.z.so.donor"
python3 "$DONORDIR/patches/patch-insns.py" libdisplay_composer_service_1.5.z.so \
    "$WORK/libdisplay_composer_service_1.5.z.so.donor" "$STAGE/vendor/lib64/libdisplay_composer_service_1.5.z.so"

echo "=== 5. Trust store (private PKI), PC configs, useriam profile ==="
sudo python3 "$HMOS_BASE/build/merge-trust.py" "$DONOR/system/system/etc/security" "$STAGE/etc/security" "$SIGN_DIR/rootCA.cer"
sudo chown -R "$(id -u):$(id -g)" "$STAGE/etc/security"

cp "$REPO/common/useriam/useriam.json" "$STAGE/system/profile/useriam.json"

sudo cat "$DONOR/system/system/etc/param/distributed_file.para" | \
    sed 's/^const.distributed_file_property.enabled=true$/const.distributed_file_property.enabled=false/' \
    > "$STAGE/etc/distributed_file.para"

# Preserve PC devicetype=2in1, disable Nearlink & HDR (no Kirin NPU/HDR hardware in QEMU)
sudo cat "$DONOR/sys_prod/etc/param/hw_defaults.para" | \
    sed -e 's/^const.nearlink.enable=true$/const.nearlink.enable=false/' \
        -e 's/^const.display.hdr_picture_support=true$/const.display.hdr_picture_support=false/' \
        -e 's/^const.display.support_aihdr_picture=true$/const.display.support_aihdr_picture=false/' \
        -e 's/^const.display.aihdr_picture_default_enable=true$/const.display.aihdr_picture_default_enable=false/' \
    > "$STAGE/etc/hw_defaults.para"

# PC display config: 220 dpi for 1920x1080 landscape desktop
sudo cat "$DONOR/sys_prod/etc/window/resources/display_manager_config.xml" | \
    sed 's|<dpi>[0-9]*</dpi>|<dpi>220</dpi>|' \
    > "$STAGE/etc/display_manager_config.xml"

cat > "$STAGE/vendor/etc/param/qemu-hmos7.para" <<'PARA'
ohos.boot.sn=HMOS7PCQEMU00001
persist.rosen.disableddgr.enabled=1
persist.sys.graphic.hdrimage.enabled=0
persist.sys.graphic.hdrvideo.enabled=0
const.debuggable=1
const.secure=0
const.hdc.secure=0
PARA

echo "=== 6. PC Init services set ==="
cp "$REPO/common/m1/etc-init/"*.cfg "$STAGE/init/"

DESKTOP_CFGS="
access_token.cfg privacy.cfg concurrent_task_service.cfg memmgrservice.cfg
storage_daemon.cfg storage_manager.cfg distributed_data.cfg accountmgr.cfg
appspawn.cfg nwebspawn.cfg installs.cfg installs_npapi.cfg foundation.cfg themeManagerServer.cfg
wallpaperservice.cfg ui_service.cfg multimodalinput.cfg inputmethodservice.cfg
pasteboardservice.cfg msdp_musl.cfg timeservice.cfg i18n_service.cfg
device_manager.cfg deviceinfoservice.cfg huks_service.cfg
compatibility_config_center.cfg powermgr.cfg faultloggerd.cfg
resource_schedule_service.cfg init.sched.cfg locationsa.cfg app_lock_service.cfg
parentcontrolservice.cfg swing_service.cfg avsession_service.cfg
CollaborationFwk.cfg resource_schedule_executor.cfg huawei_id_svc.cfg
display_engine_service.cfg netmanager_base.cfg netsysnative.cfg
useriam.cfg media_service.cfg process.cfg downloadservice.cfg srms.cfg
app_fwk_update_service.cfg hidumper_service.cfg
hdf_devmgr.cfg graphic.cfg hdcd.cfg softbus_server_musl.cfg deviceauth_service.cfg
ethernet.cfg vpnmanager.cfg virtual_keyboard_service.cfg
"
# Only pass cfgs that actually exist in PC donor
EXIST_DESKTOP=""
for c in $DESKTOP_CFGS; do
    [ -f "$DONOR/system/system/etc/init/$c" ] && EXIST_DESKTOP="$EXIST_DESKTOP $c"
done
EXIST_ONDEMAND=""
for c in $(cat "$DONORDIR/ondemand-services.txt"); do
    [ -f "$DONOR/system/system/etc/init/$c" ] && EXIST_ONDEMAND="$EXIST_ONDEMAND $c"
done

sudo python3 "$REPO/build/make-services.py" "$DONOR/system/system/etc/init" "$STAGE/init" $EXIST_DESKTOP >/dev/null
sudo python3 "$REPO/build/make-services.py" "$DONOR/system/system/etc/init" "$STAGE/init" $EXIST_ONDEMAND >/dev/null
rm -f "$STAGE/init/wifi_manager_service.cfg" "$STAGE/init/wifi_standard.cfg"
sudo python3 "$REPO/build/make-services.py" "$DONOR/system/system/etc/init" "$STAGE/init" \
    ../../../../chip_prod/etc/init/hdf_devhost.cfg:composer_host,allocator_host,user_auth_host,pin_auth_host >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$STAGE/init"

python3 - "$STAGE/init" <<'PY'
import json, os, sys
d = sys.argv[1]

p = os.path.join(d, "graphic.cfg")
if os.path.exists(p):
    cfg = json.load(open(p))
    for svc in cfg.get("services", []):
        if svc["name"] == "render_service":
            svc["path"] = ["/system/bin/render_service_launcher"]
            svc.pop("critical", None)
    json.dump(cfg, open(p, "w"), indent=4)

p = os.path.join(d, "resource_schedule_service.cfg")
if os.path.exists(p):
    cfg = json.load(open(p))
    for svc in cfg.get("services", []):
        if svc["name"] == "resource_schedule_service":
            svc["caps"] = sorted(set(svc.get("caps", [])) | {"SYS_NICE"})
    json.dump(cfg, open(p, "w"), indent=4)

for cfg_name, preload in (("accountmgr.cfg", "libsheng_account_hmac.so"),
                          ("installs.cfg", "libsheng_el5_unavailable.so"),
                          ("installs_npapi.cfg", "libsheng_el5_unavailable.so"),
                          ("appspawn.cfg", "libsheng_wifi_ui_unavailable.so"),
                          ("softbus_server_musl.cfg", "libsheng_wifi_ui_unavailable.so"),
                          ("device_manager.cfg", "libsheng_wifi_ui_unavailable.so")):
    p = os.path.join(d, cfg_name)
    if os.path.exists(p):
        cfg = json.load(open(p))
        for svc in cfg.get("services", []):
            svc["env"] = [{"name": "LD_PRELOAD", "value": "/system/lib64/" + preload}]
        json.dump(cfg, open(p, "w"), indent=4)

p = os.path.join(d, "hdcd.cfg")
if os.path.exists(p):
    cfg = json.load(open(p))
    cfg["jobs"] = [j for j in cfg.get("jobs", []) if "const.hdc.secure 1" not in " ".join(j.get("cmds", []))]
    for svc in cfg.get("services", []):
        if svc["name"] == "hdcd":
            svc["disabled"] = 0
            svc["start-mode"] = "boot"
            svc["uid"] = "root"
            svc.pop("critical", None)
            svc["gid"] = ["root", "shell", "log", "readproc", "file_manager", "netsys_socket"]
    json.dump(cfg, open(p, "w"), indent=4)
PY

cat > "$STAGE/init/qemu_m2.cfg" <<'JSON'
{
    "jobs": [
        {
            "name": "post-fs-data",
            "cmds": [
                "mkdir /data/service/el1/public/hdc 0775 root shell",
                "mkdir /data/service/el1/public/dhcp 0770 dhcp dhcp",
                "mkdir /data/service/el1/public/eth 0750 net_manager net_manager",
                "mkdir /data/service/el1/public/userauth 0700 user_auth_host user_auth_host",
                "mkdir /data/service/el1/public/pinauth 0700 pin_auth_host pin_auth_host",
                "mkdir /data/service/el1/public/dsoftbus 0771 dsoftbus dsoftbus",
                "mkdir /data/service/el1/public/database/dsoftbus 02770 dsoftbus ddms",
                "mkdir /data/data/huks_service 0700 huks_server huks_server",
                "chmod 0666 /dev/dri/card0",
                "chmod 0666 /dev/dma_heap/system",
                "chmod 0666 /dev/net/tun",
                "chmod 0666 /dev/input/event0",
                "chmod 0666 /dev/input/event1",
                "chmod 0666 /dev/input/event2",
                "setparam const.debuggable 1",
                "setparam const.secure 0",
                "setparam const.hdc.secure 0",
                "setparam const.security.developermode.state true",
                "setparam persist.rosen.disableddgr.enabled 1",
                "setparam persist.sys.graphic.hdrimage.enabled 0",
                "setparam persist.sys.graphic.hdrvideo.enabled 0",
                "setparam persist.hdc.mode tcp",
                "setparam persist.hdc.mode.tcp enable",
                "setparam persist.hdc.mode.usb disable",
                "setparam persist.hdc.port 5555",
                "setparam persist.hdc.control true",
                "setparam persist.hdc.control.shell true",
                "setparam persist.hdc.control.file true",
                "setparam persist.hdc.control.fport true",
                "start hdcd"
            ]
        },
        {
            "name": "boot",
            "cmds": [
                "start composer_host",
                "start allocator_host",
                "start user_auth_host",
                "start softbus_server",
                "start dhcp_client",
                "start hdcd"
            ]
        },
        {
            "name": "param:qemu-sceneboard-up",
            "condition": "init.sceneboard.finish=true",
            "cmds": [
                "setparam bootevent.boot.completed true",
                "start qemu_display_wake",
                "start qemu_keep_awake"
            ]
        }
    ],
    "services": [
        {
            "name": "qemu_display_wake",
            "path": ["/system/bin/power-shell", "wakeup"],
            "uid": "shell",
            "gid": ["shell"],
            "apl": "system_core",
            "permission": ["ohos.permission.POWER_MANAGER"],
            "disabled": 1,
            "once": 1,
            "sandbox": 0,
            "start-mode": "condition"
        },
        {
            "name": "qemu_keep_awake",
            "path": ["/system/bin/power-shell", "setmode", "602"],
            "uid": "shell",
            "gid": ["shell"],
            "apl": "system_core",
            "permission": ["ohos.permission.POWER_MANAGER"],
            "disabled": 1,
            "once": 1,
            "sandbox": 0,
            "start-mode": "condition"
        },
        {
            "name": "dhcp_client",
            "path": ["/system/bin/sa_main", "/system/profile/dhcp_client.json"],
            "uid": "wifi",
            "gid": ["wifi", "shell", "dhcp", "net_manager", "netsys_socket"],
            "caps": ["CAP_NET_ADMIN", "CAP_NET_BIND_SERVICE", "CAP_NET_RAW"],
            "apl": "system_basic",
            "permission": [
                "ohos.permission.NETWORK_DHCP",
                "ohos.permission.MANAGE_NET_STRATEGY",
                "ohos.permission.CONNECTIVITY_INTERNAL",
                "ohos.permission.GET_NETWORK_INFO",
                "ohos.permission.INTERNET"
            ],
            "secon": "u:r:wifi_manager_service:s0"
        }
    ]
}
JSON

mkdir -p "$STAGE/system/profile"
cat > "$STAGE/system/profile/dhcp_client.json" <<'JSON'
{
    "process": "dhcp_client",
    "systemability": [
        {
            "name": 1126,
            "libpath": "libdhcp_client.z.so",
            "run-on-create": true,
            "auto-restart": true,
            "distributed": false,
            "dump-level": 1,
            "min_hdi_proxy_version": []
        }
    ]
}
JSON

echo "=== 7. PC prep.sh ==="
cat > "$STAGE/boot/prep.sh" <<'SH'
#!/bin/sh
R=${1:-/hmos-root}
Q=/qoverlay
echo "prep: PC M2 setup on $R"

mount -t overlay -o lowerdir=$Q/vendor:/hmos/vendor overlay "$R/vendor" || echo "prep: WARN vendor overlay failed"
[ -d "$R/vendor/etc/init" ] && mount -t tmpfs -o mode=0755,size=4m hmos-init "$R/vendor/etc/init"

cp -a "$Q/system/." "$R/system/"

b() {
    [ -e "$R/$2" ] || return 0
    mount --bind "$Q/etc/$1" "$R/$2" || echo "prep: WARN bind $1 -> $2 failed"
}
b distributed_file.para system/etc/param/distributed_file.para
b hw_defaults.para sys_prod/etc/param/hw_defaults.para
b display_manager_config.xml sys_prod/etc/window/resources/display_manager_config.xml
b security/trusted_root_ca.json system/etc/security/trusted_root_ca.json
b security/trusted_apps_sources.json system/etc/security/trusted_apps_sources.json

mkdir -p "$R/dev/memcg/perf_critical" "$R/dev/memcg/perf_sensitive" 2>/dev/null || true
chmod 0666 "$R/dev/dri/card0" 2>/dev/null || true
chmod 0666 "$R/dev/dma_heap/system" 2>/dev/null || true
for ev in "$R"/dev/input/event*; do [ -c "$ev" ] && chmod 0666 "$ev" 2>/dev/null || true; done

mkdir -p "$R/data/local/tmp" "$R/data/log/hilog" "$R/data/samgr" \
         "$R/data/service/el1/public/hdc" "$R/data/service/el1/public/database/.sheng-dbkeys" \
         "$R/data/data/huks_service" "$R/storage/media"
chmod 0777 "$R/data/local/tmp"
chmod 0711 "$R/storage/media" "$R/data/service/el1/public/database/.sheng-dbkeys"
for f in render-stderr.log render-mesa.log sheng-composer-metrics.txt; do
    : > "$R/data/local/tmp/$f"
    chmod 0666 "$R/data/local/tmp/$f"
done

while IFS=: read -r name pass uid gid rest; do
    case "$uid" in ""|*[!0-9]*) continue;; esac
    [ "$uid" -lt 10000 ] || continue
    mkdir -p "$R/data/service/el1/public/database/.sheng-dbkeys/$uid"
    chown "$uid:$gid" "$R/data/service/el1/public/database/.sheng-dbkeys/$uid" 2>/dev/null || true
    chmod 0700 "$R/data/service/el1/public/database/.sheng-dbkeys/$uid"
done < "$R/system/etc/passwd"

echo "prep: PC M2 setup done ($(ls "$R/system/etc/init" | wc -l) init cfgs)"
SH
chmod 0755 "$STAGE/boot/prep.sh"

echo "=== 8. Pack 512 MiB ext4 qemu_overlay_pc.img ==="
rm -f "$OUT"
truncate -s 512M "$OUT"
mke2fs -t ext4 -b 4096 -d "$STAGE" -L qoverlay -F "$OUT" >/dev/null
ls -lh "$OUT"
echo "OVERLAY-PC-OK"
