#!/usr/bin/env bash
set -euo pipefail

# Usage: ./push.sh "commit message"
repo_root="$(cd "$(dirname "$0")" && pwd)"
cd "$repo_root"

msg=${1:-"Update"}

git submodule update --init --recursive
git add -A

if git diff --cached --quiet; then
  echo "Nothing to commit."
  exit 0
fi

git commit -m "$msg"
git push origin HEAD