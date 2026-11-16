#!/bin/bash
# tqLLM Control Center 构建脚本（CommandLineTools 环境）。
# 说明：CLT 缺少 Apple 的 SwiftUIMacros 插件，源码中 @State 已手动展开，无需 Xcode。
set -euo pipefail
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
mkdir -p .build/module-cache
CONFIG="${1:-debug}"
swift build --disable-sandbox -c "$CONFIG" \
  -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/module-cache" \
  -Xcc -fmodules-cache-path="$PWD/.build/module-cache"
echo "build ok: .build/$CONFIG/TqLLMControlCenter"