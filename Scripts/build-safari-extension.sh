#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "$0")/.." && pwd)"
readonly configuration="${CONFIGURATION:-release}"
readonly version="${VERSION:-0.1.0}"
readonly build_number="${BUILD_NUMBER:-1}"
case "${configuration}" in
    debug) readonly xcode_configuration="Debug" ;;
    release) readonly xcode_configuration="Release" ;;
    *)
        echo "Unsupported Safari extension configuration: ${configuration}" >&2
        exit 2
        ;;
esac
readonly project_root="${repository_root}/SafariExtension/Xcode/AwaitCue Safari Development Host"
readonly project_path="${project_root}/AwaitCue Safari Development Host.xcodeproj"
readonly extension_source_dir="${project_root}/AwaitCue Safari Development Host Extension"
readonly generated_sources_dir="${extension_source_dir}/GeneratedSources"
readonly build_root="${repository_root}/.build/safari"
readonly products_path="${build_root}/Build/Products"
readonly product_path="${products_path}/${xcode_configuration}/AwaitCueSafariExtension.appex"
readonly output_path="${repository_root}/dist/AwaitCueSafariExtension.appex"

cd "${repository_root}"

VERSION="${version}" npm --prefix SafariExtension run build

# Xcode project 固定受版本控制；每次构建只同步 canonical WebExtension 资源和可测试 Swift 源码。
rm -rf "${extension_source_dir}/Resources"
cp -R SafariExtension/dist "${extension_source_dir}/Resources"
mkdir -p "${generated_sources_dir}"
cp Sources/AwaitCueSafariBridge/SafariBridgeConfiguration.swift "${generated_sources_dir}/"
cp Sources/AwaitCueSafariBridge/SafariBridgeMessageCodec.swift "${generated_sources_dir}/"
cp Sources/AwaitCueSafariBridge/SafariNativeMessageBridge.swift "${generated_sources_dir}/"
cp Sources/AwaitCueBrowserBridge/LocalNativeBridge.swift "${generated_sources_dir}/"
cp Sources/AwaitCueBrowserBridge/NativeMessagingFrameCodec.swift "${generated_sources_dir}/"
cp SafariExtension/NativeHandler/AwaitCueSafariRelaySender.swift "${generated_sources_dir}/"
cp SafariExtension/NativeHandler/SafariWebExtensionHandler.swift \
    "${extension_source_dir}/SafariWebExtensionHandler.swift"
cp SafariExtension/NativeHandler/AwaitCueSafariExtension.entitlements \
    "${extension_source_dir}/AwaitCueSafariExtension.entitlements"

xcodebuild \
    -quiet \
    -project "${project_path}" \
    -target "AwaitCue Safari Development Host Extension" \
    -configuration "${xcode_configuration}" \
    CODE_SIGNING_ALLOWED=NO \
    CURRENT_PROJECT_VERSION="${build_number}" \
    MARKETING_VERSION="${version}" \
    OBJROOT="${build_root}/Build/Intermediates.noindex" \
    SYMROOT="${products_path}" \
    build

if [[ ! -d "${product_path}" ]]; then
    echo "Safari extension product is missing: ${product_path}" >&2
    exit 1
fi

rm -rf "${output_path}"
# Xcode 26 会附加 com.apple.provenance；构建产物复制时不得把该主机状态带进可发布 bundle。
cp -R -X "${product_path}" "${output_path}"
plutil -lint "${output_path}/Contents/Info.plist" >/dev/null
readonly built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${output_path}/Contents/Info.plist")"
readonly built_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${output_path}/Contents/Info.plist")"
readonly manifest_version="$(
    /usr/bin/plutil -extract version raw -o - \
        "${output_path}/Contents/Resources/manifest.json"
)"
if [[ "${built_version}" != "${version}" \
    || "${built_number}" != "${build_number}" \
    || "${manifest_version}" != "${version}" ]]
then
    echo "Safari extension version mismatch: app=${built_version}(${built_number}) manifest=${manifest_version}" >&2
    exit 3
fi

echo "Built ${output_path}"
