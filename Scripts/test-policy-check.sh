#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/awaitcue-policy-test.XXXXXX")"

cleanup() {
    rm -rf "${fixture_root}"
}
trap cleanup EXIT

mkdir -p "${fixture_root}/Scripts" "${fixture_root}/BrowserExtension"
cp "${repository_root}/Scripts/policy-check.sh" "${fixture_root}/Scripts/policy-check.sh"
chmod +x "${fixture_root}/Scripts/policy-check.sh"

for required in LICENSE NOTICE README.md CONTRIBUTING.md SECURITY.md CONTEXT.md Package.swift; do
    : > "${fixture_root}/${required}"
done
printf '{}\n' > "${fixture_root}/BrowserExtension/package.json"

git -C "${fixture_root}" init -q
git -C "${fixture_root}" config user.name "AwaitCue Policy Test"
git -C "${fixture_root}" config user.email "policy-test@invalid.example"
git -C "${fixture_root}" add .
git -C "${fixture_root}" commit -qm baseline

(
    cd "${fixture_root}"
    ./Scripts/policy-check.sh >/dev/null
)

# 合成 benchmark 图片是公开测试资产，策略不能因为扩展名而误伤它。
mkdir -p "${fixture_root}/Benchmarks/Decision/fixtures/images"
printf 'synthetic fixture\n' \
    > "${fixture_root}/Benchmarks/Decision/fixtures/images/synthetic.png"
git -C "${fixture_root}" add Benchmarks/Decision/fixtures/images/synthetic.png
(
    cd "${fixture_root}"
    ./Scripts/policy-check.sh >/dev/null
)
git -C "${fixture_root}" reset -q -- Benchmarks/Decision/fixtures/images/synthetic.png
rm -f "${fixture_root}/Benchmarks/Decision/fixtures/images/synthetic.png"

assert_private_artifact_rejected() {
    local relative_path="$1"
    mkdir -p "$(dirname "${fixture_root}/${relative_path}")"
    printf 'private benchmark artifact\n' > "${fixture_root}/${relative_path}"
    git -C "${fixture_root}" add -f "${relative_path}"
    if (
        cd "${fixture_root}"
        ./Scripts/policy-check.sh >/dev/null 2>&1
    ); then
        echo "FAIL: repository policy accepted private benchmark artifact: ${relative_path}" >&2
        exit 1
    fi
    git -C "${fixture_root}" reset -q -- "${relative_path}"
    rm -f "${fixture_root}/${relative_path}"
}

assert_private_artifact_rejected ".local/benchmarks/run.json"
assert_private_artifact_rejected "artifacts/human-review.json"
assert_private_artifact_rejected "artifacts/comparison-report.json"
assert_private_artifact_rejected "artifacts/candidate-replay.json"
assert_private_artifact_rejected "artifacts/macos-24h-example/run.json"
assert_private_artifact_rejected "artifacts/macos-24h-example/samples/0001.json"
assert_private_artifact_rejected "artifacts/macos-24h-example/samples/0001.jpg"
assert_private_artifact_rejected "artifacts/interruptibility-20261117-123456.json"

assert_private_content_rejected() {
    local relative_path="$1"
    local content="$2"
    mkdir -p "$(dirname "${fixture_root}/${relative_path}")"
    printf '%s\n' "${content}" > "${fixture_root}/${relative_path}"
    git -C "${fixture_root}" add -f "${relative_path}"
    if (
        cd "${fixture_root}"
        ./Scripts/policy-check.sh >/dev/null 2>&1
    ); then
        echo "FAIL: repository policy accepted renamed private benchmark content: ${relative_path}" >&2
        exit 1
    fi
    git -C "${fixture_root}" reset -q -- "${relative_path}"
    rm -f "${fixture_root}/${relative_path}"
}

# 文件名不是安全边界；真实复核或报告即使改名，也不能进入 Git。
assert_private_content_rejected \
    "artifacts/renamed-review.json" \
    '{"kind":"interruptibility-human-review","samples":[]}'
assert_private_content_rejected \
    "artifacts/renamed-comparison.json" \
    '{"evidenceIntegrity":{},"samplingTimeline":{},"confidenceSummary":{}}'

# 当前支持的模型服务可能使用 *_GPT_AK；拆开测试源码中的字面量，避免 policy 自测文件误报。
credential_suffix="_GPT_AK"
credential_value="ABCDEFGHIJKLMNOPQRSTUVWX${credential_suffix}"
credential_path="artifacts/renamed-config.json"
printf '{"apiKey":"%s"}\n' "${credential_value}" > "${fixture_root}/${credential_path}"
git -C "${fixture_root}" add -f "${credential_path}"
set +e
credential_output="$(
    (cd "${fixture_root}" && ./Scripts/policy-check.sh) 2>&1
)"
credential_status=$?
set -e
if [[ ${credential_status} -eq 0 ]]; then
    echo "FAIL: repository policy accepted a GPT_AK credential" >&2
    exit 1
fi
if [[ "${credential_output}" == *"${credential_value}"* ]]; then
    echo "FAIL: repository policy printed a detected credential" >&2
    exit 1
fi
git -C "${fixture_root}" reset -q -- "${credential_path}"
rm -f "${fixture_root}/${credential_path}"

# 当前树干净并不代表历史干净；提交后删除的证据 blob 仍能从 Git 恢复。
history_path="artifacts/macos-24h-history/run.json"
mkdir -p "${fixture_root}/$(dirname "${history_path}")"
printf 'private benchmark artifact\n' > "${fixture_root}/${history_path}"
git -C "${fixture_root}" add -f "${history_path}"
git -C "${fixture_root}" commit -qm "add private history fixture"
rm -f "${fixture_root}/${history_path}"
git -C "${fixture_root}" add -u "${history_path}"
git -C "${fixture_root}" commit -qm "delete private history fixture"
if (
    cd "${fixture_root}"
    ./Scripts/policy-check.sh >/dev/null 2>&1
); then
    echo "FAIL: repository policy accepted private benchmark artifact in Git history" >&2
    exit 1
fi

echo "Repository policy private-artifact behavior passed"
