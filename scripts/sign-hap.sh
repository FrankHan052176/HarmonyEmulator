#!/usr/bin/env bash
# Cross-platform HAP signer (macOS arm64 & Linux arm64) using HarmonyEmulator's private developer PKI.
# Usage: sign-hap.sh <input.hap> <output-signed.hap> [udid]
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <input.hap> <output-signed.hap> [udid]" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HMOS7_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SIGN_DIR="$ROOT/signing"
IN_HAP="$1"
OUT_HAP="$2"
UDID="${3:-$(cat "$SIGN_DIR/udid" 2>/dev/null || echo 'C419579C3E756580009C9BDF02C18160581C4897246ABB720C89B3A2E86200CC')}"
SYSTEM_APP="${SYSTEM_APP:-0}"

# Locate hap-sign-tool.jar & profile template (bundled first, then SDK fallback)
TOOL_JAR=""
TPL=""
for cand in \
    "$ROOT/tools/signing/hap-sign-tool.jar" \
    "${OHOS_SDK_HOME:-}/openharmony/toolchains/lib/hap-sign-tool.jar" \
    "${DEVECO_SDK_HOME:-}/default/openharmony/toolchains/lib/hap-sign-tool.jar"; do
    if [ -f "$cand" ]; then
        TOOL_JAR="$cand"
        TPL="$(dirname "$cand")/UnsgnedDebugProfileTemplate.json"
        break
    fi
done
if [ -z "$TOOL_JAR" ] || [ ! -f "$TPL" ]; then
    echo "ERROR: hap-sign-tool.jar or UnsgnedDebugProfileTemplate.json not found in $ROOT/tools/signing" >&2
    exit 2
fi

# Locate java
JAVA_BIN=""
for j in \
    "${HMOS7_JAVA:-}" \
    "${JAVA_HOME:+${JAVA_HOME}/bin/java}" \
    "$(command -v java 2>/dev/null || true)" \
    "/opt/homebrew/opt/openjdk/bin/java" \
    "/usr/lib/jvm/default-java/bin/java"; do
    if [ -n "$j" ] && [ -x "$j" ]; then
        JAVA_BIN="$j"
        break
    fi
done
if [ -z "$JAVA_BIN" ]; then
    echo "ERROR: java not found. Install OpenJDK 17+ or set JAVA_HOME." >&2
    exit 2
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Extract bundleName from HAP's module.json
BUNDLE_NAME="$(python3 - "$IN_HAP" <<'PY'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    m = json.loads(z.read("module.json"))
print(m["app"]["bundleName"])
PY
)"

python3 - "$TPL" "$TMP_DIR/profile.json" "$SIGN_DIR/app-release.pem" "$BUNDLE_NAME" "$UDID" "$SYSTEM_APP" <<'PY'
import json, sys
tpl_path, out_path, app_cert_path, bundle_name, udid, sys_app = sys.argv[1:]
d = json.load(open(tpl_path))
d["type"] = "debug"
d["bundle-info"]["bundle-name"] = bundle_name
d["bundle-info"]["development-certificate"] = open(app_cert_path).read().strip()
d["bundle-info"]["developer-id"] = "HMOS7QEMU"
d["debug-info"] = {"device-id-type": "udid", "device-ids": [udid]}
if sys_app == "1":
    d["bundle-info"]["app-feature"] = "hos_system_app"
    d["bundle-info"]["apl"] = "system_basic"
else:
    d["bundle-info"]["app-feature"] = "hos_normal_app"
    d["bundle-info"]["apl"] = "normal"
json.dump(d, open(out_path, "w"), indent=2)
PY

"$JAVA_BIN" -jar "$TOOL_JAR" sign-profile \
    -keyAlias "profile-release" -signAlg "SHA256withECDSA" -mode "localSign" \
    -profileCertFile "$SIGN_DIR/profile-release.pem" \
    -inFile "$TMP_DIR/profile.json" \
    -keystoreFile "$SIGN_DIR/hmos7.p12" \
    -outFile "$TMP_DIR/profile.p7b" \
    -keyPwd "123456" -keystorePwd "123456" >/dev/null

mkdir -p "$(dirname "$OUT_HAP")"
"$JAVA_BIN" -jar "$TOOL_JAR" sign-app \
    -mode "localSign" -keyAlias "app-release" \
    -appCertFile "$SIGN_DIR/app-release.pem" \
    -profileFile "$TMP_DIR/profile.p7b" \
    -inFile "$IN_HAP" \
    -keystoreFile "$SIGN_DIR/hmos7.p12" \
    -outFile "$OUT_HAP" \
    -keyPwd "123456" -keystorePwd "123456" \
    -signAlg "SHA256withECDSA" -signCode 1 >/dev/null

echo "Signed $BUNDLE_NAME -> $OUT_HAP (UDID=$UDID)"
