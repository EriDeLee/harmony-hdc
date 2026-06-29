#!/usr/bin/env bash
# 构建并签名 HAP（先出未签名包，再用 hap-sign-tool 签名）
# 签名密码等敏感信息从仓库外的 sign.hdc.env 读取（默认 ~/.local/share/HarmonyOS/signing/sign.hdc.env）
# 可用 HARMONY_SIGN_ENV 覆盖默认路径
# 用法: ./scripts/build-signed.sh
set -euo pipefail

# --- JDK ---
if [ -x /usr/lib/jvm/default/bin/java ]; then
  export JAVA_HOME=/usr/lib/jvm/default
else
  export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
fi
export PATH="$JAVA_HOME/bin:$PATH"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$PROJECT_DIR/scripts"
cd "$PROJECT_DIR"

# --- 读取签名配置 ---
SIGN_ENV="${HARMONY_SIGN_ENV:-$HOME/.local/share/HarmonyOS/signing/sign.hdc.env}"
if [ ! -f "$SIGN_ENV" ]; then
  echo "!! 找不到签名配置: $SIGN_ENV" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$SIGN_ENV"

SIGN_TOOL="$HOME/.local/share/HarmonyOS/command-line-tools/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
if [ ! -f "$SIGN_TOOL" ]; then
  echo "!! 找不到 hap-sign-tool.jar: $SIGN_TOOL" >&2
  exit 1
fi

# --- 1) 先构建未签名 HAP ---
"$SCRIPT_DIR/build-unsigned.sh"

UNSIGNED="entry/build/default/outputs/default/entry-default-unsigned.hap"
SIGNED="entry/build/default/outputs/default/entry-default-signed.hap"

# --- 2) 签名 ---
echo ">> 签名 HAP ..."
java -jar "$SIGN_TOOL" sign-app \
  -mode localSign \
  -keyAlias "$KEY_ALIAS" \
  -keyPwd "$KEY_PWD" \
  -keystoreFile "$KEYSTORE_FILE" \
  -keystorePwd "$STORE_PWD" \
  -appCertFile "$CERT_FILE" \
  -profileFile "$PROFILE_FILE" \
  -inFile "$UNSIGNED" \
  -signAlg "$SIGN_ALG" \
  -outFile "$SIGNED" \
  -signCode "1"

echo ">> 完成: $PROJECT_DIR/$SIGNED"
echo ">> 安装到设备:  hdc install -r \"$SIGNED\""
