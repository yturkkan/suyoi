#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
# Swift 6.4 defaults to swiftbuild, which currently cannot find XCTest with
# this Mac's Command Line Tools. Swift 6.0/6.1 also support the native builder.
FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ "${1:-}" == "test" && -d "$FRAMEWORKS/Testing.framework" ]]; then
    exec swift "$@" --disable-xctest --build-system native --cache-path "$PWD/.build/cache" -Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS"
fi
exec swift "$@" --build-system native --cache-path "$PWD/.build/cache"
