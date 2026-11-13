#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != arm64 ]]; then
  printf '%s\n' '仅支持 Apple Silicon 原生 arm64 构建' >&2
  exit 1
fi
if [[ "${1:-}" == --built ]]; then
  binary="${2:?--built 需要已有的 AIPassport 二进制路径}"
else
  swift build -c release --arch arm64 --product AIPassport
  binary="$(swift build -c release --arch arm64 --show-bin-path)/AIPassport"
fi
app=dist/AIPassport.app
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/AIPassport"
cp resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --identifier cn.candysun.ai-passport "$app"
printf '已生成 %s（本地 ad-hoc 签名，非公证发行包）\n' "$app"
