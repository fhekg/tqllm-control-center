#!/bin/bash
# 编译无头集成测试 CLI（与 GUI 共用服务层源码）。
set -euo pipefail
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
mkdir -p .build/module-cache build
/Library/Developer/CommandLineTools/usr/bin/swiftc \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  -target arm64-apple-macosx14.0 \
  -swift-version 5 -O \
  -module-cache-path "$PWD/.build/module-cache" \
  -Xcc -fmodules-cache-path="$PWD/.build/module-cache" \
  -framework SwiftUI -framework AppKit -framework Charts -framework Security -framework ServiceManagement \
  SourcesCLI/TqLLMCLI.swift \
  Sources/AppConfig.swift Sources/ConfigStore.swift Sources/GGUF.swift Sources/ModelScanner.swift \
  Sources/APIClient.swift Sources/EngineController.swift Sources/MonitorService.swift \
  Sources/LogService.swift Sources/BenchmarkService.swift \
  -o build/tqllmctl
echo "built build/tqllmctl"