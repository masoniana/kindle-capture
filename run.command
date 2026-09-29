#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

if ! command -v python3 >/dev/null 2>&1; then
  osascript -e 'display alert "Python 3 が必要です" message "python.org または Homebrew から Python 3.10 以降をインストールしてください。"'
  exit 1
fi

if [[ ! -x .venv/bin/python ]]; then
  python3 -m venv .venv
fi

.venv/bin/python -m pip install --quiet --upgrade pip
.venv/bin/python -m pip install --quiet -e .
exec .venv/bin/python -m kindle_capture gui
