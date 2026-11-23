#!/usr/bin/env bash
# 车机超级桌面「满屏」验证：装包 → 抓窗口几何 → 抓 [VERIFY] 日志 → 给结论
#
# 用法（在工程根目录）：
#   bash scripts/verify-car.sh              # 只体检，不重装
#   bash scripts/verify-car.sh --install    # 先重装签名包再体检
#
# 判定标准：窗口宽度 ≥ 车机屏宽的 90% 视为「已铺开」；否则仍是窄条。
set -u

HDC="${HDC:-/d/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe}"
BUNDLE="com.dudu.guoapp.car"
ABILITY="EntryAbility"
HAP="entry/build/default/outputs/default/entry-default-signed.hap"

say() { printf '%s\n' "$*"; }
hr() { say "------------------------------------------------------------"; }

# ---------- 0. 设备 ----------
hr
TARGETS="$("$HDC" list targets 2>&1 | tr -d '\r' | grep -v '^\[Empty\]$' | grep -v '^$')"
if [ -z "$TARGETS" ]; then
  say "✗ 没有连接任何设备（hdc list targets = [Empty]）"
  say ""
  say "  注意：验证车机必须让手机先连上座舱、从超级桌面把应用拉起来，"
  say "        再用 USB 把手机连到这台电脑。车机屏幕不是 hdc 目标。"
  exit 2
fi
say "设备：$TARGETS"

DEV_TYPE="$("$HDC" shell param get const.product.devicetype 2>/dev/null | tr -d '\r')"
MODEL="$("$HDC" shell param get const.product.model 2>/dev/null | tr -d '\r')"
say "机型：$MODEL    deviceType：$DEV_TYPE"

# ---------- 1. 重装（可选） ----------
if [ "${1:-}" = "--install" ]; then
  hr
  if [ ! -f "$HAP" ]; then
    say "✗ 找不到签名包：$HAP，先跑 bash scripts/build.sh release"
    exit 3
  fi
  say "安装 $HAP ..."
  # -r 覆盖安装，保留数据；不要 uninstall，那会清掉观看记录和偏好
  "$HDC" install -r "$HAP" 2>&1 | tr -d '\r'
  # 装完必须杀掉进程：超级桌面会复用已存在进程的旧窗口参数，热启动看不出改动
  "$HDC" shell aa force-stop "$BUNDLE" 2>/dev/null
  say "已强杀进程（下次从超级桌面拉起才是新配置）"
fi

# ---------- 2. 清日志并拉起 ----------
hr
"$HDC" shell hilog -r >/dev/null 2>&1
say "拉起应用（请在 5 秒内确认它出现在车机中控屏上）..."
"$HDC" shell aa start -a "$ABILITY" -b "$BUNDLE" 2>&1 | tr -d '\r'
sleep 5

# ---------- 3. 窗口几何 ----------
hr
say "▸ 窗口管理器中的窗口矩形："
DUMP="$("$HDC" shell hidumper -s WindowManagerService -a '-a' 2>/dev/null | tr -d '\r')"
if [ -z "$DUMP" ]; then
  say "  （hidumper 无输出，可能被系统限制）"
else
  # 只挑出本应用相关的窗口段，打印其 Rect
  echo "$DUMP" | grep -n -i -E "$BUNDLE|WindowName" | head -20
  say ""
  say "▸ 全部 Rect（看最大的那个，就是应用窗口）："
  echo "$DUMP" | grep -i -E "^\s*(Rect|WindowRect)\s*[:=]" | head -12
fi

say ""
say "▸ 屏幕物理尺寸："
"$HDC" shell hidumper -s RenderService -a screen 2>/dev/null | tr -d '\r' | grep -i -E "width|height|density" | head -8

# ---------- 4. 应用自己的判定日志 ----------
hr
say "▸ 应用打出的 [VERIFY] 判定日志："
LOGS="$("$HDC" shell "timeout 4 hilog -x" 2>/dev/null | tr -d '\r' | grep -E "VERIFY" | tail -20)"
if [ -z "$LOGS" ]; then
  say "  （没抓到。可能日志已滚动，试：hdc shell hilog -x | grep VERIFY）"
else
  echo "$LOGS"
fi

# ---------- 5. 结论 ----------
hr
say "▸ 结论怎么看："
say "  [VERIFY] multiwin: enable 成功 ...     → 多窗横向已开启（车机上真正治本的那一步）"
say "  [VERIFY] multiwin: enable 失败 code=.. → 多窗横向开不了，看 code：1300002 窗口状态异常 / 1300003 窗口服务异常"
say "  [VERIFY] orient: 请求横屏 ...          → 只是补刀，多窗/无 sensor 场景下可能静默无效（官方明确）"
say "  [VERIFY] fill: try#N ... target=...    → 尺寸兜底在尝试撑满"
say "  [VERIFY] fill: after=WxH@(...)         → 看 after 的 W 是否接近 target 的宽"
say ""
say "  重点看 multiwin 那两行。如果 enable 成功但窗口仍窄，"
say "  说明座舱没有按 landscape_auto 重新下发窗口，需要在座舱侧把应用加入大屏适配白名单。"
hr
