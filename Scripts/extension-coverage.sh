#!/usr/bin/env bash

set -euo pipefail

if [[ ! -f BrowserExtension/package-lock.json ]]; then
  echo "BrowserExtension/package-lock.json is missing" >&2
  exit 1
fi

npm --prefix BrowserExtension ci
npm --prefix BrowserExtension run lint
npm --prefix BrowserExtension run typecheck
npm --prefix BrowserExtension run coverage
