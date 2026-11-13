#!/usr/bin/env bash
# 只下载并安装构建依赖，不访问设备，不使用 sudo，不修改系统或 shell 配置。
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deps="${PASSPORT_DEPS_DIR:-$root/.deps}"
idf="$deps/esp-idf"
expected=2c211b236707889e8400c4dc5644dd5c4ee071e0
case "$deps" in *' '*) echo '依赖路径不能包含空格。' >&2; exit 1;; esac
command -v git >/dev/null || { echo '需要 Git。macOS 请先人工安装 Xcode Command Line Tools。' >&2; exit 1; }
command -v python3 >/dev/null || { echo '需要一个可创建 venv 的 Python 3。' >&2; exit 1; }
if [[ "$(uname -s)" == Darwin ]]; then
    xcrun --find clang >/dev/null 2>&1 || { echo '请人工安装 Xcode Command Line Tools，再重试。' >&2; exit 1; }
fi
mkdir -p "$deps"
if [[ ! -x "$deps/bootstrap/bin/uv" ]]; then
    python3 -m venv "$deps/bootstrap"
    "$deps/bootstrap/bin/python" -m pip install 'uv==0.8.22'
fi
export UV_PYTHON_INSTALL_DIR="$deps/python"
uv="$deps/bootstrap/bin/uv"
"$uv" python install 3.12.11
if [[ ! -x "$deps/host/bin/python" ]]; then
    "$uv" venv --python 3.12.11 "$deps/host"
fi
"$uv" pip install --python "$deps/host/bin/python" 'cmake==3.31.6' 'ninja==1.11.1.4'
# IDF 会自行创建 Python venv，不能以 host venv 作为 base interpreter。
# 保留 host 中的 CMake/Ninja，但让安装脚本先找到 uv 的实际 Python。
base_python="$("$deps/host/bin/python" -c 'import os, sys; print(os.path.realpath(sys._base_executable))')"
export PATH="$(dirname "$base_python"):$deps/host/bin:$PATH"
export IDF_TOOLS_PATH="$deps/tools"
if [[ ! -d "$idf/.git" ]]; then
    git clone --branch v5.5.3 --depth 1 --recursive https://github.com/espressif/esp-idf.git "$idf"
fi
[[ "$(git -C "$idf" rev-parse HEAD)" == "$expected" ]] || { echo 'ESP-IDF 版本不匹配，拒绝覆盖现有安装。' >&2; exit 1; }
git -C "$idf" submodule update --init --recursive
"$idf/install.sh" esp32c3
printf '\n依赖安装完成。构建：%s/tools/build.sh\n不会刷写任何设备。\n' "$root"
