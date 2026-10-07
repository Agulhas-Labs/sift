#!/bin/sh
#
# First-time setup for a fresh checkout: install the two style tools and activate the git hooks.

set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

echo "==== Installing SwiftLint and SwiftFormat ===="
brew install swiftlint swiftformat

echo "==== Activating git hooks ===="
git config core.hooksPath githooks

echo "==== Setup complete ===="
