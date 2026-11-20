#!/bin/bash
# Cross-compiles all M2 ARM64 HarmonyOS 7.0.0.107 native artifacts on macOS Apple Silicon
# using the installed HarmonyOS Command Line Tools 26.0.0 OHOS clang + sysroot.
set -euo pipefail

ROOT="${HMOS7_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO="$ROOT/refs/hmos-asteroids"
COMMON="$REPO/common"
QCOM="$REPO/platform/qcom"
SRC="$ROOT/refs/ohos-src"
L="$ROOT/build/ohos-link"
INC_EXT="$ROOT/build/include"
OUT="$ROOT/build/m2-native"
OHOS_SDK="${OHOS_SDK_HOME:-${DEVECO_SDK_HOME:+${DEVECO_SDK_HOME}/default}}"
SDK_NATIVE="${HMOS7_SDK_NATIVE:-${OHOS_SDK}/openharmony/native}"
HAPSIGN_JAR="${HMOS7_HAPSIGN_JAR:-${OHOS_SDK}/openharmony/toolchains/lib/hap-sign-tool.jar}"
OPENSSL_INC="/opt/homebrew/opt/openssl@3/include"

CC_BIN="$SDK_NATIVE/llvm/bin/clang"
CXX_BIN="$SDK_NATIVE/llvm/bin/clang++"
NM_BIN="$SDK_NATIVE/llvm/bin/llvm-nm"
SYSROOT="$SDK_NATIVE/sysroot"

rm -rf "$OUT"
mkdir -p "$OUT"/{vendor/lib64/passthrough/indirect,system/lib64,system/bin,bin,obj-huks,obj-useriam}

BASE_CF="--target=aarch64-linux-ohos --sysroot=$SYSROOT -O2 -fPIC -fuse-ld=lld"
CPP_CHIPSET="$CXX_BIN $BASE_CF -std=c++17 -fno-exceptions -fno-rtti -nostdlib++ -include $COMMON/include/platform_cpp_config.h"
CPP_CHIPSET_EXC="$CXX_BIN $BASE_CF -std=c++17 -fno-rtti -nostdlib++ -include $COMMON/include/platform_cpp_config.h"
C_FLAGS="$CC_BIN $BASE_CF -std=gnu11"

echo "=== 1. Display VDIs (virtio-gpu composer + linear dma_heap buffer) ==="
VDI_INC="-I$QCOM/display -I$QCOM/display/include/vdi-only -I$QCOM/display/include -I$QCOM/display/include/display/buffer \
  -I$SRC/drivers_hdf_core/interfaces/inner_api/hdi/base \
  -I$SRC/drivers_peripheral/display/buffer/hdi_service/include \
  -I$SRC/drivers_interface/display/composer/common/include \
  -I$SRC/hiviewdfx_hilog/interfaces/native/innerkits/include \
  -I$INC_EXT -I$INC_EXT/libdrm"

$CPP_CHIPSET $VDI_INC -Wall -Wextra -Wno-unused-parameter -shared -Wl,-z,defs \
  -Wl,-soname,libdisplay_composer_vdi_impl.z.so \
  "$ROOT/src/display/composer_vdi.cpp" "$QCOM/display/composer_unsupported.cpp" \
  "$L/libdrm.so" "$L/libc++.so" \
  -o "$OUT/vendor/lib64/libdisplay_composer_vdi_impl.z.so"

$CPP_CHIPSET $VDI_INC -Wall -Wextra -Wno-unused-parameter -DACE5_LINEAR_STRIDE_ALIGNMENT=8 \
  -shared -Wl,-z,defs -Wl,-soname,libdisplay_buffer_vdi_impl.z.so \
  "$QCOM/display/buffer_vdi.cpp" "$L/libc++.so" \
  -o "$OUT/vendor/lib64/passthrough/indirect/libdisplay_buffer_vdi_impl.z.so"

echo "=== 2. SwiftShader Vulkan OHOS ICD wrapper (vulkan.hvgr_v200.so) ==="
$CXX_BIN $BASE_CF -std=c++17 -fno-exceptions -fno-rtti -Wall -Wextra -Wno-unused-parameter \
  -shared -Wl,-z,defs -Wl,-soname,vulkan.hvgr_v200.so \
  "$ROOT/src/vulkan/vulkan_swiftshader_ohos.cpp" -ldl \
  -o "$OUT/vendor/lib64/passthrough/vulkan.hvgr_v200.so"

echo "=== 3. Framework no-TEE shims (account_hmac, dbkeys, el5, sceneboard_optional_sa) ==="
HUKS_INC="$SRC/security_huks/interfaces/inner_api/huks_standard/main/include"
$C_FLAGS -I"$HUKS_INC" -I"$OPENSSL_INC" -Wno-misleading-indentation -shared -Wl,-z,relro,-z,now \
  -Wl,--version-script="$COMMON/framework/account_hmac.map" \
  "$COMMON/framework/account_hmac.c" "$L/libcrypto_openssl.z.so" -Wl,--allow-shlib-undefined \
  -o "$OUT/system/lib64/libsheng_account_hmac.so"

$C_FLAGS -I"$HUKS_INC" -I"$OPENSSL_INC" -Wno-misleading-indentation -shared -Wl,-z,relro,-z,now \
  -Wl,--version-script="$COMMON/framework/db_key.map" -Wl,-soname,libdbkeys.so \
  "$COMMON/framework/db_key.c" "$L/libhukssdk.z.so" "$L/libcrypto_openssl.z.so" -Wl,--allow-shlib-undefined \
  -o "$OUT/system/lib64/libdbkeys.so"

$C_FLAGS -shared -Wl,-z,relro,-z,now \
  "$COMMON/framework/el5_unavailable.c" \
  -o "$OUT/system/lib64/libsheng_el5_unavailable.so"

$C_FLAGS -shared -Wl,-z,relro,-z,now -ldl \
  "$ROOT/src/framework/wifi_unavailable_qemu.c" \
  -o "$OUT/system/lib64/libsheng_wifi_ui_unavailable.so"

mkdir -p "$OUT/system/lib64/module/hms/core/appgalleryservice"
$C_FLAGS -shared -Wl,-z,relro,-z,now -Wl,-soname,libprivacymanager_napi.z.so \
  "$ROOT/src/framework/privacymanager_napi_qemu.c" -lace_napi.z \
  -o "$OUT/system/lib64/module/hms/core/appgalleryservice/libprivacymanager_napi.z.so"

$CXX_BIN $BASE_CF -std=c++17 -fno-exceptions -fno-rtti -nostdlib++ -shared -Wl,-z,relro,-z,now \
  "$COMMON/framework/sceneboard_optional_sa.cpp" -ldl \
  -o "$OUT/system/lib64/libsheng_sceneboard_optional_sa.so"

echo "=== 4. Software HUKS engine (libhuks_ca_hdi.z.so) ==="
H="$SRC/security_huks"
F="$H/frameworks/huks_standard/main"
E="$H/services/huks_standard/huks_engine/main"
SV="$H/services/huks_standard/huks_service/main"
HUKS_SRCS="
$E/core/src/hks_auth.c $E/core/src/hks_core_interfaces.c $E/core/src/hks_core_service_key_attest.c
$E/core/src/hks_core_service_key_generate.c $E/core/src/hks_core_service_key_operate_one_stage.c
$E/core/src/hks_core_service_key_operate_three_stage.c $E/core/src/hks_core_service_key_other.c
$E/core/src/hks_core_service_three_stage.c $E/core/src/hks_keyblob.c $E/core/src/hks_keynode.c
$E/core/src/hks_secure_access.c $E/core/src/hks_sm_import_wrap_key.c $E/core/src/hks_upgrade_key.c
$E/device_cert_manager/src/dcm_asn1.c $E/device_cert_manager/src/dcm_attest.c
$E/device_cert_manager/src/dcm_attest_utils.c
$F/common/src/hks_ability.c $F/common/src/hks_base_check.c $F/common/src/hks_check_paramset.c
$F/common/src/hks_common_check.c $F/common/src/hks_crypto_adapter.c $F/common/src/hks_error_msg.c
$F/common/src/hks_param.c $F/common/src/hks_tags_type_manager.c $F/common/src/hks_errcode_adapter.c
$F/crypto_engine/crypto_common/src/hks_core_ability.c $F/crypto_engine/crypto_common/src/hks_core_get_main_key.c
$F/os_dependency/posix/hks_mem.c $F/os_dependency/posix/hks_util.c
$H/utils/crypto_adapter/hks_client_service_adapter.c $H/utils/crypto_adapter/hks_client_service_adapter_common.c
$H/utils/file_operator/hks_file_operator.c $H/utils/list/hks_double_list.c $H/utils/mutex/hks_mutex.c
$F/crypto_engine/rkc/src/hks_rkc.c $F/crypto_engine/rkc/src/hks_rkc_rw.c $F/crypto_engine/rkc/src/hks_rkc_v1.c
$SV/os_dependency/posix/hks_rwlock.c
$SV/hks_storage/src/hks_lock.c $SV/hks_storage/src/hks_storage.c $SV/hks_storage/src/hks_storage_file_lock.c
$SV/hks_storage/src/hks_storage_manager.c $SV/hks_storage/src/hks_storage_utils.c
$F/os_dependency/sysinfo/src/hks_get_process_info_passthrough.c $F/os_dependency/sysinfo/src/hks_get_udid.c
$COMMON/framework/huks_engine_extra.c
"
for s in 3des ability aes bn common curve25519 des dh dsa ecc ed25519tox25519 engine hash hmac kdf rsa sm2 sm3 sm4; do
  HUKS_SRCS="$HUKS_SRCS $F/crypto_engine/openssl/src/hks_openssl_$s.c"
done

HUKS_INC_DIRS=$(find "$H/frameworks" "$H/services" "$H/utils" "$H/interfaces" -name '*.h' -not -path '*/test/*' -not -path '*lite*' -exec dirname {} \; | sort -u | sed 's/^/-I/')
HUKS_ALL_INC="$HUKS_INC_DIRS -I$OPENSSL_INC -I$SRC/third_party_bounds_checking_function/include -I$SRC/hiviewdfx_hilog/interfaces/native/innerkits/include"
HUKS_DEFS='-DHKS_KEY_VERSION=3 -D_HUKS_LOG_ENABLE_ -DL2_STANDARD -DHKS_ENABLE_CLEAN_FILE -DSUPPORT_STORAGE_BACKUP -DHKS_ENABLE_UPGRADE_KEY -DHKS_CHANGE_DERIVE_KEY_ALG_TO_HKDF -DHKS_USE_RKC_IN_STANDARD -DHKS_CONFIG_KEY_STORE_PATH="/data/service/el1/public/huks_service" -DHKS_CONFIG_RKC_STORE_PATH="/data/data/huks_service" -DHKS_ENABLE_UPGRADE_RKC_DERIVE_ALG -DOPENSSL_SUPPRESS_DEPRECATED -DLOG_DOMAIN=0xD002F00 -DLOG_TAG="HUKS"'

HUKS_OBJS=()
for s in $HUKS_SRCS; do
  o="$OUT/obj-huks/$(basename "$s" .c).o"
  $C_FLAGS -w $HUKS_DEFS $HUKS_ALL_INC -c "$s" -o "$o"
  HUKS_OBJS+=("$o")
done
$C_FLAGS -shared -Wl,-soname,libhuks_ca_hdi.z.so -Wl,--version-script="$COMMON/framework/huks_engine.map" \
  -Wl,-z,relro,-z,now -Wl,-z,defs "${HUKS_OBJS[@]}" \
  "$L/libcrypto_openssl.z.so" "$L/libsec_shared.z.so" "$L/libhilog.so" \
  -o "$OUT/vendor/lib64/passthrough/indirect/libhuks_ca_hdi.z.so"
echo "HUKS exports: $($NM_BIN -D --defined-only "$OUT/vendor/lib64/passthrough/indirect/libhuks_ca_hdi.z.so" | grep -c HuksHdi)"

echo "=== 5. Software UserIAM (user_auth_host) ==="
B="$COMMON/useriam"
A="$SRC/drivers_peripheral/user_auth/hdi_service"
HDF="$SRC/drivers_hdf_core/interfaces/inner_api"
UIAM_INC="-I$OPENSSL_INC -I$B/generated -I$B/generated/user_auth -I$A/interface -I$A/adaptor/inc -I$A/coauth/inc \
  -I$A/common/inc -I$A/database/inc -I$A/idm/inc -I$A/key_mgr/inc -I$A/user_auth/inc -I$A/utils/inc -I$A/service \
  -I$A/../common/logs -I$A/../common/utils -I$SRC/third_party_bounds_checking_function/include \
  -I$SRC/hiviewdfx_hilog/interfaces/native/innerkits/include -I$SRC/commonlibrary_c_utils/base/include \
  -I$SRC/communication_ipc/interfaces/innerkits/ipc_core/include -I$HDF/utils -I$HDF/hdi -I$HDF/hdi/base \
  -I$HDF/host/shared -I$HDF/core -I$HDF/ipc -I$HDF/osal/uhdf -I$HDF/osal/shared"

UIAM_OBJS=()
for src in $(sed -n '1,/external_deps/p' "$A/BUILD.gn" | grep -o -E '"[^"]+\.(c|cpp)"' | tr -d '"'); do
  p="$A/$src"
  [ "$src" = "service/user_auth_interface_service.cpp" ] && p="$B/user_auth_interface_service.cpp"
  o="$OUT/obj-useriam/$(echo "$src" | tr '/' '_').o"
  UIAM_OBJS+=("$o")
  if [ "${p##*.}" = "cpp" ]; then
    $CPP_CHIPSET_EXC -w $UIAM_INC -c "$p" -o "$o"
  else
    $C_FLAGS -w $UIAM_INC -c "$p" -o "$o"
  fi
done

$CPP_CHIPSET_EXC $UIAM_INC -shared -Wl,-z,defs -Wl,-soname,libsheng_userauth_4_0.so "${UIAM_OBJS[@]}" \
  "$L/libc++.so" "$L/libutils.z.so" "$L/libhilog.so" "$L/libhdf_utils.z.so" "$L/libhdi.z.so" \
  "$L/libipc_single.z.so" "$L/libcrypto_openssl.z.so" "$L/libsec_shared.z.so" "$L/libuser_auth_stub_4.0.z.so" \
  -o "$OUT/vendor/lib64/libsheng_userauth_4_0.so"

INC41="-I$B/generated41 -I$B/generated41/user_auth"
$CPP_CHIPSET_EXC $UIAM_INC $INC41 -shared -Wl,-z,defs -Wl,-soname,libuser_auth_interface_service_4.1.z.so \
  "$B/adapter41.cpp" "$L/libc++.so" "$L/libutils.z.so" -ldl \
  -o "$OUT/vendor/lib64/libuser_auth_interface_service_4.1.z.so"

HDFINC="-I$HDF/host/uhdf $(for h in hdf_device_desc.h hdf_sbuf_ipc.h hdf_object_manager.h hdf_device_section.h; do find "$SRC/drivers_hdf_core" -name "$h" -exec dirname {} \; ; done | sort -u | sed 's/^/-I/' | tr '\n' ' ')"
$CPP_CHIPSET_EXC $UIAM_INC $INC41 $HDFINC -D__USER__ -shared -Wl,-z,defs -Wl,-soname,libuser_auth_driver.z.so \
  "$B/driver41.cpp" "$OUT/vendor/lib64/libuser_auth_interface_service_4.1.z.so" \
  "$L/libc++.so" "$L/libutils.z.so" "$L/libhilog.so" "$L/libhdf_utils.z.so" "$L/libhdi.z.so" \
  "$L/libipc_single.z.so" "$L/libuser_auth_stub_4.0.z.so" "$L/libuser_auth_stub_4.1.z.so" \
  "$L/libhdf_host.z.so" "$L/libhdf_ipc_adapter.z.so" -ldl -Wl,--allow-shlib-undefined \
  -o "$OUT/vendor/lib64/libuser_auth_driver.z.so"

echo "=== 6. Helper tools (render_service_launcher, capture_scanout, tap) ==="
$CC_BIN $BASE_CF -Wall -Wextra "$COMMON/services/render_service_launcher.c" -o "$OUT/system/bin/render_service_launcher"
$CC_BIN $BASE_CF -Wall -Wextra "$COMMON/services/capture_scanout.c" -o "$OUT/system/bin/capture_scanout"
$CC_BIN $BASE_CF -Wall -Wextra -static "$COMMON/services/tap.c" -o "$OUT/bin/tap"

echo "=== 7. Private self-signing PKI (hmos7-qemu) ==="
SIGN_DIR="$ROOT/signing"
mkdir -p "$SIGN_DIR"
if [ ! -f "$SIGN_DIR/hmos7.p12" ]; then
  (
    cd "$SIGN_DIR"
    J="java -jar $HAPSIGN_JAR"
    KS=hmos7.p12; P=123456; O="C=CN,O=HMOS7QEMU,OU=HMOS7QEMU"
    for a in a-root a-ca a-app a-prof; do
      $J generate-keypair -keyAlias "$a" -keyAlg ECC -keySize NIST-P-256 -keystoreFile $KS -keystorePwd $P -keyPwd $P >/dev/null
    done
    $J generate-ca -keyAlias a-root -subject "$O,CN=HMOS7QEMU Root CA" -validity 7300 -signAlg SHA256withECDSA \
      -keystoreFile $KS -keystorePwd $P -keyPwd $P -outFile rootCA.cer -keyAlg ECC -keySize NIST-P-256 >/dev/null
    $J generate-ca -keyAlias a-ca -issuer "$O,CN=HMOS7QEMU Root CA" -issuerKeyAlias a-root -issuerKeyPwd $P \
      -subject "$O,CN=HMOS7QEMU Signing CA" -validity 7300 -signAlg SHA256withECDSA \
      -keystoreFile $KS -keystorePwd $P -keyPwd $P -outFile signCA.cer -keyAlg ECC -keySize NIST-P-256 >/dev/null
    $J generate-app-cert -keyAlias a-app -issuer "$O,CN=HMOS7QEMU Signing CA" -issuerKeyAlias a-ca -issuerKeyPwd $P \
      -subject "$O,CN=HMOS7QEMU Application Release" -validity 7300 -signAlg SHA256withECDSA \
      -keystoreFile $KS -keystorePwd $P -keyPwd $P -subCaCertFile signCA.cer -rootCaCertFile rootCA.cer \
      -outForm certChain -outFile app-release.pem >/dev/null
    $J generate-profile-cert -keyAlias a-prof -issuer "$O,CN=HMOS7QEMU Signing CA" -issuerKeyAlias a-ca -issuerKeyPwd $P \
      -subject "$O,CN=HMOS7QEMU Profile Release" -validity 7300 -signAlg SHA256withECDSA \
      -keystoreFile $KS -keystorePwd $P -keyPwd $P -subCaCertFile signCA.cer -rootCaCertFile rootCA.cer \
      -outForm certChain -outFile profile-release.pem >/dev/null
  )
fi
ls -lh "$OUT/vendor/lib64/" "$OUT/vendor/lib64/passthrough/" "$OUT/vendor/lib64/passthrough/indirect/" "$OUT/system/lib64/" "$OUT/system/bin/" "$SIGN_DIR/"
echo "M2-NATIVE-OK"
