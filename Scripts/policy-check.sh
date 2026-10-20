#!/usr/bin/env bash

set -euo pipefail

git diff --check

if git ls-files --error-unmatch .codex/session-state.md >/dev/null 2>&1; then
  echo ".codex/session-state.md must remain local and untracked" >&2
  exit 1
fi

if git grep -nEI '(Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{16,}|sk-[A-Za-z0-9_-]{16,})' -- ':!Scripts/policy-check.sh'; then
  echo "A value resembling an API credential is tracked" >&2
  exit 1
fi

for required in LICENSE NOTICE README.md CONTRIBUTING.md SECURITY.md CONTEXT.md Package.swift BrowserExtension/package.json; do
  if [[ ! -e "${required}" ]]; then
    echo "Required repository file is missing: ${required}" >&2
    exit 1
  fi
done

echo "Repository policy checks passed"
