#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TASK_ROOT/.build" "$TASK_ROOT/qa"
swiftc -O -D TESTING -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macosx13.0 \
  "$TASK_ROOT/Sources/MiniStatus.swift" -o "$TASK_ROOT/.build/MiniStatusTests" -framework AppKit -framework SwiftUI
"$TASK_ROOT/.build/MiniStatusTests" --self-test
"$TASK_ROOT/.build/MiniStatusTests" --audit
"$TASK_ROOT/.build/MiniStatusTests" --render-preview "$TASK_ROOT/qa/overview.png"
"$TASK_ROOT/.build/MiniStatusTests" --render-preview "$TASK_ROOT/qa/cache.png" --cache
"$TASK_ROOT/.build/MiniStatusTests" --render-preview "$TASK_ROOT/qa/apps-dark.png" --apps --dark
