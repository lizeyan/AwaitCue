#!/usr/bin/env bash

set -euo pipefail

git diff --check

if git ls-files --error-unmatch .codex/session-state.md >/dev/null 2>&1; then
  echo ".codex/session-state.md must remain local and untracked" >&2
  exit 1
fi

# `.gitignore` 不能阻止显式 `git add -f`；Git 历史中的已删除 blob 也仍然可以恢复。
private_benchmark_artifacts="$({
  git ls-files
  git log --all --name-only --format=
} | sed '/^$/d' | sort -u | grep -E \
  '(^|/)\.local/|(^|/)(human-review|comparison-report|candidate-replay)\.json$|(^|/)macos-24h-[^/]+/(run\.json|samples/)|(^|/)interruptibility-[0-9]{8}-[0-9]{6}\.json$' \
  || true)"
if [[ -n "${private_benchmark_artifacts}" ]]; then
  echo "Private benchmark artifacts must remain local and untracked:" >&2
  printf '%s\n' "${private_benchmark_artifacts}" >&2
  exit 1
fi

# 改名不能绕过保护；这些组合只匹配真实采样、盲审和报告 JSON 的稳定结构。
has_private_benchmark_signature() {
  local content
  content="$(cat)"
  if printf '%s' "${content}" | grep -Eq \
    '"kind"[[:space:]]*:[[:space:]]*"interruptibility-(human-review|reviewed-replay-(plan|report))"'; then
    return 0
  fi
  if printf '%s' "${content}" | grep -Eq '"evidenceIntegrity"[[:space:]]*:' \
      && printf '%s' "${content}" | grep -Eq '"samplingTimeline"[[:space:]]*:' \
      && printf '%s' "${content}" | grep -Eq '"confidenceSummary"[[:space:]]*:'; then
    return 0
  fi
  if printf '%s' "${content}" | grep -Eq '"imageFile"[[:space:]]*:[[:space:]]*"samples/' \
      && printf '%s' "${content}" | grep -Eq '"modelDecision"[[:space:]]*:' \
      && printf '%s' "${content}" | grep -Eq '"humanDecision"[[:space:]]*:'; then
    return 0
  fi
  if printf '%s' "${content}" | grep -Eq '"intendedEndAt"[[:space:]]*:' \
      && printf '%s' "${content}" | grep -Eq '"lastEvidenceAttemptAt"[[:space:]]*:' \
      && printf '%s' "${content}" | grep -Eq '"lockedPollCount"[[:space:]]*:'; then
    return 0
  fi
  return 1
}

private_benchmark_content=""
while IFS= read -r tracked_json; do
  [[ -n "${tracked_json}" ]] || continue
  if git show ":${tracked_json}" | has_private_benchmark_signature; then
    private_benchmark_content+="${tracked_json}"$'\n'
  fi
done < <(git ls-files '*.json')

# 扫描所有可达历史 JSON blob；按 object ID 去重，避免同一文件跨提交重复读取。
while IFS= read -r object_id; do
  [[ -n "${object_id}" ]] || continue
  [[ "$(git cat-file -t "${object_id}")" == "blob" ]] || continue
  if git cat-file blob "${object_id}" | has_private_benchmark_signature; then
    private_benchmark_content+="git-object:${object_id}"$'\n'
  fi
done < <(git rev-list --objects --all -- '*.json' | awk '{print $1}' | sort -u)

if [[ -n "${private_benchmark_content}" ]]; then
  echo "Private benchmark JSON content must remain local and outside Git history:" >&2
  printf '%s' "${private_benchmark_content}" >&2
  exit 1
fi

credential_pattern='Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{16,}|sk-[A-Za-z0-9_-]{16,}|[A-Za-z0-9_-]{16,}_GPT_AK'
credential_hits="$({
  git grep -nEI "${credential_pattern}" -- ':!Scripts/policy-check.sh' || true
  git grep -nEI "${credential_pattern}" $(git rev-list --all) \
    -- ':!Scripts/policy-check.sh' || true
} | sort -u)"
if [[ -n "${credential_hits}" ]]; then
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
