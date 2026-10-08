#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64 "$@"
ARM_BUILD="$(swift build -c release --arch arm64 --show-bin-path "$@")"
swift build -c release --arch x86_64 "$@"
INTEL_BUILD="$(swift build -c release --arch x86_64 --show-bin-path "$@")"
mkdir -p .build
lipo -create "$ARM_BUILD/TypstEdit" "$INTEL_BUILD/TypstEdit" -output .build/TypstEdit-universal
APP_ARCH=universal BUNDLE_EXECUTABLE=.build/TypstEdit-universal ./bundle.sh
