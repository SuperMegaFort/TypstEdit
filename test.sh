#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TEST_BUILD="${TEST_BUILD_DIR:-/private/tmp/typstedit-regression}"
mkdir -p "$TEST_BUILD/module-cache"
swiftc -swift-version 5 -parse-as-library -module-cache-path "$TEST_BUILD/module-cache" \
  Sources/LanguageSupport.swift Sources/LanguageServer.swift Sources/LanguageAssistViews.swift Sources/Localization.swift Sources/CompilerSettings.swift Sources/TypstCompiler.swift \
  Sources/EditorController.swift Sources/LineNumberRulerView.swift Sources/SyntaxHighlighter.swift Sources/DocumentWorkspace.swift Sources/GitModel.swift Sources/GitDecorations.swift Sources/GitReviewViews.swift Sources/DocumentWindowGuard.swift \
  Sources/SnippetsManager.swift Sources/EditorView.swift Sources/PreviewView.swift Sources/ThemeManager.swift Tests/CompilerTests.swift -o "$TEST_BUILD/regression"
"$TEST_BUILD/regression"
