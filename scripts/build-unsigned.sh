#!/usr/bin/env bash
# 构建未签名 HAP
# 用法: ./scripts/build-unsigned.sh [额外的 hvigorw 参数]
set -euo pipefail

# --- JDK：优先用 archlinux-java 的 default 软链，否则回退到 java-17 ---
if [ -x /usr/lib/jvm/default/bin/java ]; then
  export JAVA_HOME=/usr/lib/jvm/default
else
  export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
fi
export PATH="$JAVA_HOME/bin:$PATH"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo ">> JAVA_HOME=$JAVA_HOME"
echo ">> 构建未签名 HAP ..."
hvigorw assembleHap --no-daemon "$@"

HAP="entry/build/default/outputs/default/entry-default-unsigned.hap"
echo ">> 完成: $PROJECT_DIR/$HAP"
