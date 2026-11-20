#!/bin/bash
# Builds M2 qemu_overlay.img (full HarmonyOS 7.0.0.107 desktop: virtio-gpu display/SwiftShader Vulkan/Mesa GLES,
# binary patches, software HUKS/UserIAM/dbkeys, private signing PKI trust store, and desktop services) inside Lima.
set -euo pipefail

ROOT="${HMOS7_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO="$ROOT/refs/hmos-asteroids"
DONORDIR="$REPO/donor/pura70proplus-7.0.0.107"
DONOR=/tmp/donor-mnt
OHOSREF=/tmp/ohos-ref
NATIVE="$ROOT/build/m2-native"
SIGN_DIR="$ROOT/signing"
OUT="$ROOT/out/qemu_overlay.img"
STAGE=/tmp/hmos7-m2-stage

rm -rf "$STAGE"
mkdir -p "$STAGE"/{bin,boot,etc/oobe,etc/security,init,system/bin,system/lib64/chipset-sdk,system/lib64/platformsdk,system/profile,vendor/lib64/passthrough/indirect,vendor/etc/param}

echo "=== 1. Busybox & helper binaries ==="
cp /bin/busybox "$STAGE/bin/busybox"
chmod 0755 "$STAGE/bin/busybox"
cp "$NATIVE/bin/tap" "$STAGE/bin/tap"
cp "$NATIVE/system/bin/render_service_launcher" "$STAGE/system/bin/"
cp "$NATIVE/system/bin/capture_scanout" "$STAGE/system/bin/"
chmod 0755 "$STAGE/bin/tap" "$STAGE/system/bin/render_service_launcher" "$STAGE/system/bin/capture_scanout"

echo "=== 2. Native VDIs, SwiftShader Vulkan ICD, HUKS, UserIAM, framework shims ==="
cp "$NATIVE/vendor/lib64/libdisplay_composer_vdi_impl.z.so" "$STAGE/vendor/lib64/"
cp "$NATIVE/vendor/lib64/libsheng_userauth_4_0.so" "$STAGE/vendor/lib64/"
cp "$NATIVE/vendor/lib64/libuser_auth_interface_service_4.1.z.so" "$STAGE/vendor/lib64/"
cp "$NATIVE/vendor/lib64/libuser_auth_driver.z.so" "$STAGE/vendor/lib64/"
cp "$NATIVE/vendor/lib64/passthrough/vulkan.hvgr_v200.so" "$STAGE/vendor/lib64/passthrough/"
cp "$NATIVE/vendor/lib64/passthrough/indirect/libdisplay_buffer_vdi_impl.z.so" "$STAGE/vendor/lib64/passthrough/indirect/"
cp "$NATIVE/vendor/lib64/passthrough/indirect/libhuks_ca_hdi.z.so" "$STAGE/vendor/lib64/passthrough/indirect/"
cp "$NATIVE/system/lib64/"*.so "$STAGE/system/lib64/"
mkdir -p "$STAGE/system/lib64/module/hms/core/appgalleryservice"
cp "$NATIVE/system/lib64/module/hms/core/appgalleryservice/libprivacymanager_napi.z.so" \
   "$STAGE/system/lib64/module/hms/core/appgalleryservice/libprivacymanager_napi.z.so"

echo "=== 3. Prebuilt ohos-qemu SwiftShader + Mesa GLES/swrast + libdrm ==="
sudo cp "$OHOSREF/system/system/lib64/libvk_swiftshader.so" "$STAGE/vendor/lib64/passthrough/libvk_swiftshader.so"
sudo cp "$OHOSREF/system/system/lib64/chipset-sdk/libdrm.so" "$STAGE/vendor/lib64/libdrm.so"
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

echo "=== 4. Donor binary patches (no-TEE DB keys, code-sign, key-enable, UI non-blocking, present-fence) ==="
WORK=/tmp/hmos7-m2-patchwork
rm -rf "$WORK" && mkdir -p "$WORK"

while read -r lib prefix names; do
    sudo cat "$DONOR/system/system/lib64/$lib" > "$WORK/$lib.donor"
    python3 "$DONORDIR/patches/patch-huks-imports.py" "$WORK/$lib.donor" "$STAGE/system/lib64/$lib" "$prefix" $names
done <<'LIBS'
librelational_store_crypt.z.so S Abort Finish GenerateKey GenerateRandom Init KeyExist Update
libkv_store_crypt.z.so S Decrypt Encrypt GenerateKey GenerateRandom KeyExist
libdistributeddatasvcfwk.z.so D Decrypt Encrypt GenerateKey GenerateRandom KeyExist
LIBS

sudo cat "$DONOR/system/system/lib64/libcode_sign_utils.z.so" > "$WORK/libcode_sign_utils.z.so.donor"
python3 "$DONORDIR/patches/patch-code-sign.py" "$WORK/libcode_sign_utils.z.so.donor" "$STAGE/system/lib64/libcode_sign_utils.z.so"

sudo cat "$DONOR/system/system/lib64/libkey_enable.z.so" > "$WORK/libkey_enable.z.so.donor"
python3 "$DONORDIR/patches/patch-key-enable.py" "$WORK/libkey_enable.z.so.donor" "$STAGE/system/lib64/libkey_enable.z.so"

for f in platformsdk/libaudio_policy_client.z.so platformsdk/libsensor_client.z.so \
         libsps_privacy_indicator_service_intf.z.so platformsdk/libwifi_sdk.z.so \
         platformsdk/libnet_tether_manager_if.z.so platformsdk/libcli_tool_client.z.so \
         libpowermgrservice.z.so libtime_system_ability.z.so platformsdk/libsensor_utils.z.so \
         libmemmgrservice.z.so libmovement_ar.z.so; do
    sudo cat "$DONOR/system/system/lib64/$f" > "$WORK/$(basename "$f").donor"
    mkdir -p "$(dirname "$STAGE/system/lib64/$f")"
    python3 "$DONORDIR/patches/patch-insns.py" "$(basename "$f")" "$WORK/$(basename "$f").donor" "$STAGE/system/lib64/$f"
done

sudo cat "$DONOR/vendor/lib64/libdisplay_composer_service_1.5.z.so" > "$WORK/libdisplay_composer_service_1.5.z.so.donor"
python3 "$DONORDIR/patches/patch-insns.py" libdisplay_composer_service_1.5.z.so \
    "$WORK/libdisplay_composer_service_1.5.z.so.donor" "$STAGE/vendor/lib64/libdisplay_composer_service_1.5.z.so"

echo "=== 5. Trust store (private PKI), configs, OOBE, useriam profile ==="
sudo python3 "$ROOT/build/merge-trust.py" "$DONOR/system/system/etc/security" "$STAGE/etc/security" "$SIGN_DIR/rootCA.cer"
sudo chown -R "$(id -u):$(id -g)" "$STAGE/etc/security"

cp "$REPO/common/useriam/useriam.json" "$STAGE/system/profile/useriam.json"
cp "$REPO/common/init/oobe_page.json" "$STAGE/etc/oobe/oobe_page.json"
sudo cat "$DONOR/sys_prod/etc/oobe/hwupgrade_extend_pages.json" > "$STAGE/etc/oobe/hwupgrade_extend_pages.json"

sudo cat "$DONOR/system/system/etc/param/distributed_file.para" | \
    sed 's/^const.distributed_file_property.enabled=true$/const.distributed_file_property.enabled=false/' \
    > "$STAGE/etc/distributed_file.para"

sudo cat "$DONOR/sys_prod/etc/param/hw_defaults.para" | \
    sed -e 's/^const.nearlink.enable=true$/const.nearlink.enable=false/' \
        -e 's/^const.display.hdr_picture_support=true$/const.display.hdr_picture_support=false/' \
        -e 's/^const.display.support_aihdr_picture=true$/const.display.support_aihdr_picture=false/' \
        -e 's/^const.display.aihdr_picture_default_enable=true$/const.display.aihdr_picture_default_enable=false/' \
        -e 's/^const.product.name=.*/const.product.name=HMOS7-QEMU/' \
        -e '/^const.product.model=/d' \
    > "$STAGE/etc/hw_defaults.para"
echo "const.product.model=HMOS7-QEMU" >> "$STAGE/etc/hw_defaults.para"

cat > "$STAGE/etc/display_manager_config.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Configs>
  <dpi>420</dpi>
  <defaultDeviceRotationOffset>0</defaultDeviceRotationOffset>
  <cutoutArea>0 0 0 0</cutoutArea>
  <defaultDisplayCutoutPath></defaultDisplayCutoutPath>
  <rotationPolicy>11</rotationPolicy>
  <supportRotateWithSensor enable="false"/>
  <externalScreenDefaultMode>mirror</externalScreenDefaultMode>
  <castBundleName>com.huawei.hmos.huaweicast</castBundleName>
  <castAbilityName>CastSourceServiceAbility</castAbilityName>
</Configs>
XML

cat > "$STAGE/vendor/etc/param/qemu-hmos7.para" <<'PARA'
ohos.boot.sn=HMOS7QEMU00000001
persist.rosen.disableddgr.enabled=1
persist.sys.graphic.hdrimage.enabled=0
persist.sys.graphic.hdrvideo.enabled=0
const.debuggable=1
const.secure=0
const.hdc.secure=0
PARA

echo "=== 6. Init services set (desktop + ondemand + HDF display/useriam + hdcd) ==="
cp "$REPO/common/m1/etc-init/"*.cfg "$STAGE/init/"

DESKTOP_CFGS="
access_token.cfg privacy.cfg concurrent_task_service.cfg memmgrservice.cfg
storage_daemon.cfg storage_manager.cfg distributed_data.cfg accountmgr.cfg
appspawn.cfg nwebspawn.cfg installs.cfg foundation.cfg themeManagerServer.cfg
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
hdf_devmgr.cfg graphic.cfg hdcd.cfg softbus_server_musl.cfg deviceauth_service.cfg ethernet.cfg vpnmanager.cfg
"
sudo python3 "$REPO/build/make-services.py" "$DONOR/system/system/etc/init" "$STAGE/init" $DESKTOP_CFGS >/dev/null
sudo python3 "$REPO/build/make-services.py" "$DONOR/system/system/etc/init" "$STAGE/init" $(cat "$DONORDIR/ondemand-services.txt") >/dev/null
rm -f "$STAGE/init/wifi_manager_service.cfg" "$STAGE/init/wifi_standard.cfg"
sudo python3 "$REPO/build/make-services.py" "$DONOR/system/system/etc/init" "$STAGE/init" \
    ../../../../chip_prod/etc/init/hdf_devhost.cfg:composer_host,allocator_host,user_auth_host,pin_auth_host >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$STAGE/init"

# Patch service configs (LD_PRELOADs, render_service_launcher, resource_schedule_service caps, hdcd TCP root)
python3 - "$STAGE/init" <<'PY'
import json, os, sys

d = sys.argv[1]

# graphic.cfg: use render_service_launcher & add DRM/dma_heap gids + disable DDGR
p = os.path.join(d, "graphic.cfg")
cfg = json.load(open(p))
for svc in cfg.get("services", []):
    if svc["name"] == "render_service":
        svc["path"] = ["/system/bin/render_service_launcher"]
        svc.pop("critical", None)
json.dump(cfg, open(p, "w"), indent=4)

# resource_schedule_service.cfg: CAP_SYS_NICE for v1 cgroups
p = os.path.join(d, "resource_schedule_service.cfg")
cfg = json.load(open(p))
for svc in cfg.get("services", []):
    if svc["name"] == "resource_schedule_service":
        svc["caps"] = sorted(set(svc.get("caps", [])) | {"SYS_NICE"})
json.dump(cfg, open(p, "w"), indent=4)

# Preloads for accountmgr (HMAC without TEE), installs (EL5 unavailable without TEE), appspawn/softbus/dm (fast Wi-Fi skip)
for cfg_name, preload in (("accountmgr.cfg", "libsheng_account_hmac.so"),
                          ("installs.cfg", "libsheng_el5_unavailable.so"),
                          ("appspawn.cfg", "libsheng_wifi_ui_unavailable.so"),
                          ("softbus_server_musl.cfg", "libsheng_wifi_ui_unavailable.so"),
                          ("device_manager.cfg", "libsheng_wifi_ui_unavailable.so")):
    p = os.path.join(d, cfg_name)
    cfg = json.load(open(p))
    for svc in cfg.get("services", []):
        svc["env"] = [{"name": "LD_PRELOAD", "value": "/system/lib64/" + preload}]
    json.dump(cfg, open(p, "w"), indent=4)

# hdcd.cfg: unattended localhost TCP hdcd as root
p = os.path.join(d, "hdcd.cfg")
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

echo "=== 7. M2 prep.sh ==="
cat > "$STAGE/boot/prep.sh" <<'SH'
#!/bin/sh
R=${1:-/hmos-root}
Q=/qoverlay
echo "prep: M2 setup on $R"

# 1. Overlay /vendor (our composer/buffer VDIs, SwiftShader Vulkan ICD, Mesa GLES, HUKS, UserIAM, vendor params)
mount -t overlay -o lowerdir=$Q/vendor:/hmos/vendor overlay "$R/vendor" || echo "prep: WARN vendor overlay failed"
# Re-hide donor vendor/etc/init so Kirin vendor services never launch
[ -d "$R/vendor/etc/init" ] && mount -t tmpfs -o mode=0755,size=4m hmos-init "$R/vendor/etc/init"

# 2. Copy our /system overlay files (patched donor libs, shims, render_service_launcher, useriam.json, swrast)
cp -a "$Q/system/." "$R/system/"

# 3. Bind configs over donor read-only partitions
b() { mount --bind "$Q/etc/$1" "$R/$2" || echo "prep: WARN bind $1 -> $2 failed"; }
b distributed_file.para system/etc/param/distributed_file.para
b oobe sys_prod/etc/oobe
b hw_defaults.para sys_prod/etc/param/hw_defaults.para
b display_manager_config.xml sys_prod/etc/window/resources/display_manager_config.xml
b security/trusted_root_ca.json system/etc/security/trusted_root_ca.json
b security/trusted_apps_sources.json system/etc/security/trusted_apps_sources.json

# 4. Device nodes & cgroups required by render_service / allocator_host / composer_host / multimodalinput
mkdir -p "$R/dev/memcg/perf_critical" "$R/dev/memcg/perf_sensitive" 2>/dev/null || true
chmod 0666 "$R/dev/dri/card0" 2>/dev/null || true
chmod 0666 "$R/dev/dma_heap/system" 2>/dev/null || true
for ev in "$R"/dev/input/event*; do [ -c "$ev" ] && chmod 0666 "$ev" 2>/dev/null || true; done

# 5. Pre-create writable log files & per-UID dbkeys dirs for libdbkeys.so
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

echo "prep: M2 setup done ($(ls "$R/system/etc/init" | wc -l) init cfgs)"
SH
chmod 0755 "$STAGE/boot/prep.sh"

echo "=== 8. Pack 512 MiB ext4 qemu_overlay.img ==="
rm -f "$OUT"
truncate -s 512M "$OUT"
mke2fs -t ext4 -b 4096 -d "$STAGE" -L qoverlay -F "$OUT" >/dev/null
ls -lh "$OUT"
echo "OVERLAY-M2-OK"
