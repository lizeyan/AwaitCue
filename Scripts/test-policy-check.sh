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

echo "Repository policy private-artifact behavior passed"
