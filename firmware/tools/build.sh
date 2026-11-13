#!/usr/bin/env bash
# 只构建和合并 full.bin。没有 flash/erase/monitor 操作。
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deps="${PASSPORT_DEPS_DIR:-$root/.deps}"
idf="${PASSPORT_IDF_DIR:-${IDF_PATH:-$deps/esp-idf}}"
build="${PASSPORT_BUILD_DIR:-$root/build}"
if [[ ! -f "$idf/export.sh" ]]; then
    echo '缺少 ESP-IDF 5.5.3，请先运行 firmware/tools/bootstrap.sh。' >&2; exit 1
fi
if [[ -d "$deps/host/bin" ]]; then export PATH="$deps/host/bin:$PATH"; fi
if [[ "$idf" == "$deps/esp-idf" ]]; then export IDF_TOOLS_PATH="$deps/tools"; fi
# ESP-IDF export.sh 内部会读取未定义变量，临时关闭 nounset。
set +u
source "$idf/export.sh" >/dev/null
set -u
[[ "$(idf.py --version)" == 'ESP-IDF v5.5.3' ]] || { echo '仅支持 ESP-IDF v5.5.3。' >&2; exit 1; }
mkdir -p "$build"
# 构建配置留在 build 下，不覆盖开发者的 sdkconfig。
idf.py -C "$root" -B "$build" -D "SDKCONFIG=$build/sdkconfig" \
    -D "SDKCONFIG_DEFAULTS=$root/sdkconfig.defaults" -D IDF_TARGET=esp32c3 build
idf.py -C "$root" -B "$build" merge-bin -o full.bin
printf '\n合并镜像：%s/full.bin（起始偏移 0x0；未刷写）\n' "$build"
printf '调试文件：%s/ai_passport_panel.elf 与对应 .map\n' "$build"
