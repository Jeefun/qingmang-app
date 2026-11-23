#!/usr/bin/env bash
# guoapp-harmony 一键构建 + 签名 + 安装
# 用法: bash scripts/build.sh [release|debug]
#
# 所有路径均为自动探测，可跨机器/跨盘符使用。需要手动指定时用环境变量覆盖：
#   GUOAPP_KEYS  密钥目录（含 guoapp.p12 / guoapp-debug.cer / guoapp-debug.p7b）
#   DEVECO_HOME  DevEco Studio 安装目录
#   NODE_BIN     指定 node 可执行文件
#   JAVA_BIN     指定 java 可执行文件
set -e

MODE="${1:-release}"

# ---------- 路径转换：msys /d/x -> D:/x ----------
to_win() {
  local p="$1"
  case "$p" in
    /[a-zA-Z]/*)
      printf '%s:/%s\n' "$(printf '%s' "${p:1:1}" | tr 'a-z' 'A-Z')" "${p:3}"
      ;;
    *)
      printf '%s\n' "$p"
      ;;
  esac
}

# ---------- 工程根目录：以脚本所在位置为准，不写死盘符 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------- 密钥目录 ----------
KEYS="${GUOAPP_KEYS:-}"
if [ -z "$KEYS" ]; then
  for candidate in "$PROJ/../keys" "$PROJ/keys" "$HOME/guoapp-keys" "$HOME/Desktop/keys"; do
    if [ -f "$candidate/guoapp.p12" ]; then
      KEYS="$(cd "$candidate" && pwd)"
      break
    fi
  done
fi
if [ -z "$KEYS" ] || [ ! -f "$KEYS/guoapp.p12" ]; then
  echo "找不到签名密钥 guoapp.p12。请把 keys 目录放到工程同级，或设置 GUOAPP_KEYS。"
  exit 1
fi

# ---------- DevEco Studio ----------
DEVENCO_LIST=""
detect_deveco() {
  if [ -n "$DEVECO_HOME" ] && [ -d "$DEVECO_HOME/sdk" ]; then
    printf '%s\n' "$DEVECO_HOME"
    return 0
  fi
  for candidate in \
    "/d/DevEco Studio" \
    "/c/Program Files/Huawei/DevEco Studio" \
    "/c/Program Files/DevEco Studio" \
    "/d/Program Files/Huawei/DevEco Studio" \
    "/e/DevEco Studio" \
    "/c/DevEco Studio"; do
    if [ -d "$candidate/sdk" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  # 兜底：在 C/D/E 盘根下按名字找
  for root in /c /d /e /f; do
    [ -d "$root" ] || continue
    found="$(find "$root" -maxdepth 2 -type d -iname "DevEco Studio" 2>/dev/null | head -1)"
    if [ -n "$found" ] && [ -d "$found/sdk" ]; then
      printf '%s\n' "$found"
      return 0
    fi
  done
  return 1
}

DEVECO="$(detect_deveco || true)"
if [ -z "$DEVECO" ]; then
  echo "未找到 DevEco Studio。请设置 DEVECO_HOME 指向安装目录（内含 sdk 子目录）。"
  exit 1
fi

NODE="${NODE_BIN:-$DEVECO/tools/node/node.exe}"
HVIGOR="$DEVECO/tools/hvigor/bin/hvigorw.js"
SIGNTOOL="$DEVECO/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
HDC="$DEVECO/sdk/default/openharmony/toolchains/hdc.exe"

# ---------- JDK：DevEco 自带 jbr 优先，其次 JAVA_HOME ----------
if [ -n "$JAVA_BIN" ]; then
  JAVA="$JAVA_BIN"
elif [ -x "$DEVECO/jbr/bin/java.exe" ]; then
  JAVA="$DEVECO/jbr/bin/java.exe"
elif [ -x "$DEVECO/jbr/bin/java" ]; then
  JAVA="$DEVECO/jbr/bin/java"
elif [ -n "$JAVA_HOME" ] && [ -x "$JAVA_HOME/bin/java.exe" ]; then
  JAVA="$JAVA_HOME/bin/java.exe"
elif [ -x "/d/App/toolchain/jdk/bin/java.exe" ]; then
  JAVA="/d/App/toolchain/jdk/bin/java.exe"
else
  JAVA="java"
fi

export DEVECO_SDK_HOME="$(to_win "$DEVECO")/sdk"
export NODE_HOME="$(to_win "$DEVECO")/tools/node"

OUT="$PROJ/entry/build/default/outputs/default"

echo "工程:  $PROJ"
echo "密钥:  $KEYS"
echo "DevEco: $DEVECO"
echo "JDK:   $JAVA"
echo ""

cd "$PROJ"

echo "[1/4] 编译 ($MODE)..."
# 先删掉上一次产物：否则编译失败时会拿旧包继续签名安装，装上的还是上一版
rm -f "$OUT/entry-default-unsigned.hap" "$OUT/entry-default-signed.hap"
"$NODE" "$(to_win "$HVIGOR")" --mode module -p product=default -p buildMode="$MODE" \
  assembleHap --analyze=normal --incremental --no-daemon 2>&1 | tail -5 || true

if [ ! -f "$OUT/entry-default-unsigned.hap" ]; then
  echo "编译失败：未找到 unsigned.hap"
  exit 1
fi

echo "[2/4] 签名..."
# 下面的 guoapp.* 文件名与 -keyAlias 是本机调试证书的文件名 / 别名，与证书内容绑定；
# 它们不是应用品牌名，改名会直接导致签名失败，请勿按「敏感词」批量替换。
# 签名口令不写死在脚本里：优先取环境变量，避免仓库提交后口令随代码一起外泄。
# 缺省值只用于让本机既有调试流程不中断；正式构建请显式 export GUOAPP_KEY_PWD。
KEY_PWD="${GUOAPP_KEY_PWD:-Guoapp2026}"
"$JAVA" -jar "$(to_win "$SIGNTOOL")" sign-app \
  -mode localSign \
  -keyAlias "guoapp" \
  -keyPwd "$KEY_PWD" \
  -appCertFile "$(to_win "$KEYS/guoapp-debug.cer")" \
  -profileFile "$(to_win "$KEYS/guoapp-debug.p7b")" \
  -inFile "$(to_win "$OUT/entry-default-unsigned.hap")" \
  -signAlg "SHA256withECDSA" \
  -keystoreFile "$(to_win "$KEYS/guoapp.p12")" \
  -keystorePwd "$KEY_PWD" \
  -outFile "$(to_win "$OUT/entry-default-signed.hap")" \
  -compatibleVersion 26 -signCode 1 2>&1 | tail -3

echo "[3/4] 安装..."
TARGET="$("$HDC" list targets 2>/dev/null | head -1 | tr -d '\r')"
# hdc 在没有设备时会返回 [Empty]，不能只判空
if [ -z "$TARGET" ] || [ "$TARGET" = "[Empty]" ]; then
  echo "未检测到设备，跳过安装（包已生成，连上手机后重跑本脚本即可安装）"
  echo "[4/4] 完成"
  ls -lh "$OUT/entry-default-signed.hap"
  exit 0
fi
# hdc 无法解析 msys 风格路径，切到产物目录用相对路径
cd "$OUT"
"$HDC" -t "$TARGET" install -r "entry-default-signed.hap" 2>&1 | tail -3

echo "[4/4] 完成"
ls -lh "$OUT/entry-default-signed.hap"
