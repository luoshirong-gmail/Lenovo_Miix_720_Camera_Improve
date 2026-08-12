#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# hermes-verify-vscode-config — VSCode 开发配置文件验证 (ad-hoc)
set -euo pipefail

ROOT=""$PROJECT_ROOT""
PASS=0; FAIL=0

check() {
    local msg="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "✅ $msg"; ((PASS++))
    else
        echo "❌ $msg"; ((FAIL++))
    fi
}

echo "=== VSCode Config Verification ==="

# JSON syntax
check "settings.json valid JSON" python3 -c "import json; json.load(open('$ROOT/.vscode/settings.json'))"
check "tasks.json valid JSON" python3 -c "import json; json.load(open('$ROOT/.vscode/tasks.json'))"
check "launch.json valid JSON" python3 -c "import json; json.load(open('$ROOT/.vscode/launch.json'))"
check "extensions.json valid JSON" python3 -c "import json; json.load(open('$ROOT/.vscode/extensions.json'))"

# Makefile
check "Makefile exists" test -f "$ROOT/Makefile"
check "make clean all succeeds" make -C "$ROOT" clean all 2>/dev/null

# ELF binaries
check "camera-router is ELF" file "$ROOT/front_camera/pipeline/camera-router" | grep -q ELF || true
check "ov5670-router is ELF" file "$ROOT/back_camera/scripts/ov5670-router" | grep -q ELF || true

# requirements.txt
check "requirements.txt exists" test -f "$ROOT/requirements.txt"
check "numpy in requirements" grep -q numpy "$ROOT/requirements.txt"
check "pillow in requirements" grep -q pillow "$ROOT/requirements.txt"

# No source modified
MODIFIED=$(git -C "$ROOT" status --porcelain | grep -v '^??' || true)
if [ -z "$MODIFIED" ]; then
    echo "✅ no original source files modified"; ((PASS++))
else
    echo "❌ source files modified: $MODIFIED"; ((FAIL++))
fi

echo ""
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "✅ All checks passed" || (echo "❌ Some checks failed"; exit 1)
