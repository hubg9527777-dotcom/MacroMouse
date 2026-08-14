#!/usr/bin/env bash
# build.sh <arm64|x86_64|universal>
# universal 会构建 arm64 和 x86_64 两个切片，生成可原生运行于 Apple Silicon 与 Intel 的安装包。
set -euo pipefail

ARCH="${1:-}"
APP_NAME="MacroMouse"

case "${ARCH}" in
    arm64)    LABEL="macOS" ;;
    x86_64)   LABEL="Intel" ;;
    universal) LABEL="macOS" ;;
    *)
        echo "❌ 用法: ./build.sh <arm64|x86_64|universal>"
        exit 1
        ;;
esac

APP_DIR="dist/${APP_NAME}.app"
BIN_DEST="${APP_DIR}/Contents/MacOS/${APP_NAME}"
ZIP_NAME="${APP_NAME}-${LABEL}.zip"

build_single_arch() {
    local target_arch="$1"
    local destination="$2"
    local legacy_bin=".build/${target_arch}-apple-macosx/release/${APP_NAME}"
    local xcbuild_bin=".build/out/Products/Release/${APP_NAME}"
    local candidate=""

    echo "🔨 编译 ${target_arch}..."
    swift build -c release --product "${APP_NAME}" --arch "${target_arch}" -j 1

    if [ -f "${legacy_bin}" ]; then
        candidate="${legacy_bin}"
    elif [ -f "${xcbuild_bin}" ]; then
        candidate="${xcbuild_bin}"
    else
        candidate="$(find .build -type f -name "${APP_NAME}" \( -path "*/Release/*" -o -path "*/release/*" \) -not -path "*.dSYM/*" 2>/dev/null | head -1 || true)"
    fi

    if [ -z "${candidate}" ] || [ ! -f "${candidate}" ]; then
        echo "❌ 找不到 ${target_arch} 可执行文件"
        exit 1
    fi
    cp "${candidate}" "${destination}"
}

rm -rf dist
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

if [ "${ARCH}" = "universal" ]; then
    temp_dir="$(mktemp -d)"
    trap 'rm -rf "${temp_dir}"' EXIT
    build_single_arch arm64 "${temp_dir}/${APP_NAME}-arm64"
    build_single_arch x86_64 "${temp_dir}/${APP_NAME}-x86_64"
    echo "🧬 合并通用二进制（arm64 + x86_64）..."
    lipo -create "${temp_dir}/${APP_NAME}-arm64" "${temp_dir}/${APP_NAME}-x86_64" -output "${BIN_DEST}"
    lipo -info "${BIN_DEST}"
else
    build_single_arch "${ARCH}" "${BIN_DEST}"
fi

cp "Resources/Info.plist" "${APP_DIR}/Contents/"
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/"
fi

echo "✍️  ad-hoc 签名..."
codesign --force --deep -s - "${APP_DIR}"

echo "🗜  压缩为 ${ZIP_NAME}..."
( cd dist && ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "${ZIP_NAME}" )
echo "✅ 完成：dist/${ZIP_NAME}"
