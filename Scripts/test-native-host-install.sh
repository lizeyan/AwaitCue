#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "$0")/.." && pwd)"
readonly temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/awaitcue-native-host-install.XXXXXX")"
readonly fixture_app="${temporary_root}/AwaitCue Test.app"
readonly host_executable="${fixture_app}/Contents/MacOS/AwaitCueNativeHost"
readonly escaped_fixture_app="${temporary_root}/AwaitCue \"Quoted\"\\Test.app"
readonly escaped_host_executable="${escaped_fixture_app}/Contents/MacOS/AwaitCueNativeHost"
readonly first_manifest_directory="${temporary_root}/Chrome Profile A/NativeMessagingHosts"
readonly second_manifest_directory="${temporary_root}/Chrome Profile B/NativeMessagingHosts"
readonly manifest_name="org.awaitcue.native.json"
readonly first_extension_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
readonly second_extension_id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

cleanup() {
    rm -rf "${temporary_root}"
}
trap cleanup EXIT

mkdir -p "$(dirname "${host_executable}")"
printf '#!/usr/bin/env bash\nexit 0\n' > "${host_executable}"
chmod 755 "${host_executable}"
mkdir -p "$(dirname "${escaped_host_executable}")"
printf '#!/usr/bin/env bash\nexit 0\n' > "${escaped_host_executable}"
chmod 755 "${escaped_host_executable}"

install_fixture() {
    local extension_id="$1"
    AWAITCUE_NATIVE_MESSAGING_DIRS="${first_manifest_directory}:${second_manifest_directory}" \
    AWAITCUE_EXTENSION_ID="${extension_id}" \
        "${repository_root}/Scripts/install-native-host.sh" "${fixture_app}"
}

install_fixture "${first_extension_id}"

for directory in "${first_manifest_directory}" "${second_manifest_directory}"; do
    manifest="${directory}/${manifest_name}"
    test -f "${manifest}"
    jq -e . "${manifest}" >/dev/null
    test "$(jq -r '.name' "${manifest}")" = "org.awaitcue.native"
    test "$(jq -r '.path' "${manifest}")" = "${host_executable}"
    test "$(jq -r '.allowed_origins[0]' "${manifest}")" \
        = "chrome-extension://${first_extension_id}/"
    test "$(stat -f '%Lp' "${manifest}")" = "600"
done

# 重复安装必须原子替换旧 origin，不能保留已经变化的 unpacked extension ID。
install_fixture "${second_extension_id}"
readonly first_manifest="${first_manifest_directory}/${manifest_name}"
test "$(jq -r '.allowed_origins[0]' "${first_manifest}")" \
    = "chrome-extension://${second_extension_id}/"
readonly manifest_hash_before_invalid="$(shasum -a 256 "${first_manifest}" | awk '{print $1}')"

if AWAITCUE_NATIVE_MESSAGING_DIRS="${first_manifest_directory}" \
    AWAITCUE_EXTENSION_ID="invalid-id" \
    "${repository_root}/Scripts/install-native-host.sh" "${fixture_app}" >/dev/null 2>&1
then
    echo "Invalid extension ID unexpectedly succeeded." >&2
    exit 1
fi
test "$(shasum -a 256 "${first_manifest}" | awk '{print $1}')" \
    = "${manifest_hash_before_invalid}"

# Native Messaging manifest 是 JSON；包含引号或反斜杠的合法本地路径也必须正确转义。
AWAITCUE_NATIVE_MESSAGING_DIRS="${first_manifest_directory}" \
AWAITCUE_EXTENSION_ID="${first_extension_id}" \
    "${repository_root}/Scripts/install-native-host.sh" "${escaped_fixture_app}"
jq -e . "${first_manifest}" >/dev/null
test "$(jq -r '.path' "${first_manifest}")" = "${escaped_host_executable}"

if AWAITCUE_NATIVE_MESSAGING_DIRS="${first_manifest_directory}" \
    AWAITCUE_EXTENSION_ID="${first_extension_id}" \
    "${repository_root}/Scripts/install-native-host.sh" \
        "${temporary_root}/Missing.app" >/dev/null 2>&1
then
    echo "Missing native host unexpectedly succeeded." >&2
    exit 1
fi

echo "Native Host clean-install behavior passed."
