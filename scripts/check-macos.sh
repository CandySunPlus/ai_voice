#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 不依赖完整 Xcode、XCTest 或编译器宏插件。
swift build --product AIPassport
swift run ProtocolChecks
