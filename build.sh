#!/bin/bash
#
#  LCSwitcher 插件独立构建脚本
#  一键编译出适用于 LiveContainer / Gnoix 的 arm64 架构 .dylib 动态库及 .deb 插件包
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_NAME="LCSwitcher"
DYLIB_OUT="${SCRIPT_DIR}/${OUTPUT_NAME}.dylib"
DEB_DIR="${SCRIPT_DIR}/deb_package"

echo "======================================================="
echo "🚀 开始构建 LiveContainer 全能应用切换器插件 (${OUTPUT_NAME})"
echo "======================================================="

# 1. 检查 Xcode / SDK 工具链
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
if [[ -z "$SDK_PATH" ]]; then
    echo "❌ 未检测到 iOS SDK，请确保已安装 Xcode 且执行过 xcode-select"
    exit 1
fi
echo "📱 使用 iOS SDK: ${SDK_PATH}"

# 2. 编译 arm64 架构 .dylib (纯原生零依赖，兼容 iOS 16+)
echo "🔨 正在编译 ${OUTPUT_NAME}.dylib (arm64)..."
xcrun --sdk iphoneos clang \
    -arch arm64 \
    -miphoneos-version-min=16.0 \
    -isysroot "${SDK_PATH}" \
    -fobjc-arc \
    -dynamiclib \
    -fvisibility=hidden \
    -install_name "@loader_path/${OUTPUT_NAME}.dylib" \
    -framework Foundation \
    -framework UIKit \
    -framework CoreGraphics \
    -framework QuartzCore \
    -framework AVKit \
    -framework AVFoundation \
    -I "${SCRIPT_DIR}" \
    -O3 \
    -o "${DYLIB_OUT}" \
    "${SCRIPT_DIR}/${OUTPUT_NAME}.m"

# 3. 符号剥离与尺寸极致优化
echo "✂️ 正在精简符号表..."
strip -x "${DYLIB_OUT}"

# 4. 代码签名
SIGN_ID="${SIGN_IDENTITY:-${CERT_NAME:-"-"}}"
if [[ "$SIGN_ID" != "-" ]]; then
    echo "🔏 使用指定的开发者证书执行签名 (${SIGN_ID})..."
    codesign -s "${SIGN_ID}" --force "${DYLIB_OUT}" 2>/dev/null || true
else
    echo "🔏 正在进行 Ad-Hoc 临时签名..."
    codesign -s - --force "${DYLIB_OUT}" 2>/dev/null || true
fi

FILE_SIZE=$(stat -f%z "${DYLIB_OUT}" 2>/dev/null || stat -c%s "${DYLIB_OUT}" 2>/dev/null || echo "未知")
echo "✅ ${OUTPUT_NAME}.dylib 构建成功！"
echo "📦 文件路径: ${DYLIB_OUT}"
echo "📏 文件大小: $((FILE_SIZE / 1024)) KB (${FILE_SIZE} bytes)"

# 5. 生成配套注入配置文件 .plist
cat <<EOF > "${SCRIPT_DIR}/${OUTPUT_NAME}.plist"
{
    Filter = {
        Mode = "Any";
        Bundles = (
            "com.apple.UIKit"
        );
    };
}
EOF

# 6. 打包为标准 .deb 越狱/容器插件包 (优先使用 dpkg-deb，无工具链时自动采用纯原生物理封装)
DEB_FILE="${SCRIPT_DIR}/${OUTPUT_NAME}_1.3.2_iphoneos-arm.deb"
echo "📦 正在打包为 .deb 插件包..."

if command -v dpkg-deb >/dev/null 2>&1; then
    rm -rf "${DEB_DIR}"
    mkdir -p "${DEB_DIR}/DEBIAN"
    mkdir -p "${DEB_DIR}/Library/MobileSubstrate/DynamicLibraries"

    cat <<EOF > "${DEB_DIR}/DEBIAN/control"
Package: cn.oily.lcswitcher
Name: LCSwitcher
Version: 1.3.2
Architecture: iphoneos-arm
Description: LiveContainer / Gnoix 单任务快速切换侧边栏插件
Maintainer: Gnoix Team
Author: Oily
Section: Tweaks
Depends: mobilesubstrate (>= 0.9.5000)
EOF

    cp -f "${DYLIB_OUT}" "${DEB_DIR}/Library/MobileSubstrate/DynamicLibraries/"
    cp -f "${SCRIPT_DIR}/${OUTPUT_NAME}.plist" "${DEB_DIR}/Library/MobileSubstrate/DynamicLibraries/"

    dpkg-deb -b -Zxz "${DEB_DIR}" "${DEB_FILE}" >/dev/null 2>&1 || \
    dpkg-deb -b "${DEB_DIR}" "${DEB_FILE}"
    rm -rf "${DEB_DIR}"
else
    # 原生 Python 封装标准 Debian .deb 归档包 (完全对齐 ar + tar 结构)
    python3 -c "
import os, tarfile, io

pkg_dir = '${SCRIPT_DIR}'
deb_file = '${DEB_FILE}'
dylib_path = '${DYLIB_OUT}'
plist_path = '${SCRIPT_DIR}/${OUTPUT_NAME}.plist'

control_content = '''Package: cn.oily.lcswitcher
Name: LCSwitcher
Version: 1.3.2
Architecture: iphoneos-arm
Description: LiveContainer / Gnoix 单任务快速切换侧边栏插件
Maintainer: Gnoix Team
Author: Oily
Section: Tweaks
Depends: mobilesubstrate (>= 0.9.5000)
'''

tmp_dir = '/tmp/lcswitcher_deb_build'
os.makedirs(tmp_dir, exist_ok=True)

with open(f'{tmp_dir}/debian-binary', 'wb') as f:
    f.write(b'2.0\n')

# control.tar.gz
with tarfile.open(f'{tmp_dir}/control.tar.gz', 'w:gz') as tar:
    data = control_content.encode('utf-8')
    ti = tarfile.TarInfo('./control')
    ti.size = len(data)
    ti.mode = 0o644
    tar.addfile(ti, io.BytesIO(data))

# data.tar.gz
with tarfile.open(f'{tmp_dir}/data.tar.gz', 'w:gz') as tar:
    with open(dylib_path, 'rb') as f:
        dylib_data = f.read()
    ti = tarfile.TarInfo('./Library/MobileSubstrate/DynamicLibraries/${OUTPUT_NAME}.dylib')
    ti.size = len(dylib_data)
    ti.mode = 0o755
    tar.addfile(ti, io.BytesIO(dylib_data))
    
    with open(plist_path, 'rb') as f:
        plist_data = f.read()
    ti2 = tarfile.TarInfo('./Library/MobileSubstrate/DynamicLibraries/${OUTPUT_NAME}.plist')
    ti2.size = len(plist_data)
    ti2.mode = 0o644
    tar.addfile(ti2, io.BytesIO(plist_data))

# 组装为标准 ar 归档
with open(f'{tmp_dir}/debian-binary', 'rb') as f: db = f.read()
with open(f'{tmp_dir}/control.tar.gz', 'rb') as f: ct = f.read()
with open(f'{tmp_dir}/data.tar.gz', 'rb') as f: dt = f.read()

entries = [('debian-binary', db), ('control.tar.gz', ct), ('data.tar.gz', dt)]
with open(deb_file, 'wb') as f:
    f.write(b'!<arch>\n')
    for name, data in entries:
        name_field = f'{name:<16}'[:16].encode('ascii')
        mtime_field = f'{\"1700000000\":<12}'[:12].encode('ascii')
        uid_field = f'{\"0\":<6}'[:6].encode('ascii')
        gid_field = f'{\"0\":<6}'[:6].encode('ascii')
        mode_field = f'{\"100644\":<8}'[:8].encode('ascii')
        size_field = f'{str(len(data)):<10}'[:10].encode('ascii')
        fmag = b'\x60\n'
        f.write(name_field + mtime_field + uid_field + gid_field + mode_field + size_field + fmag)
        f.write(data)
        if len(data) % 2 != 0:
            f.write(b'\n')
"
fi

DEB_SIZE=$(stat -f%z "${DEB_FILE}" 2>/dev/null || echo "0")
echo "🎉 .deb 插件包已生成: ${DEB_FILE} ($((DEB_SIZE / 1024)) KB)"

# 7. 打包为一键导入的 .zip 压缩包 (包含 .dylib 与配套 .plist)
ZIP_FILE="${SCRIPT_DIR}/${OUTPUT_NAME}.zip"
echo "📦 正在打包为 .zip 插件压缩包..."
(cd "${SCRIPT_DIR}" && zip -q -9 "${ZIP_FILE}" "${OUTPUT_NAME}.dylib" "${OUTPUT_NAME}.plist")
ZIP_SIZE=$(stat -f%z "${ZIP_FILE}" 2>/dev/null || echo "0")
echo "🎉 .zip 插件包已生成: ${ZIP_FILE} ($((ZIP_SIZE / 1024)) KB)"

# 8. 同步至工程 Frameworks 目录供整体 IPA 打包
mkdir -p "${SCRIPT_DIR}/../../Frameworks"
cp -f "${DYLIB_OUT}" "${SCRIPT_DIR}/../../Frameworks/"
cp -f "${SCRIPT_DIR}/${OUTPUT_NAME}.plist" "${SCRIPT_DIR}/../../Frameworks/"

echo "======================================================="
echo "💡 插件产物一览："
echo "1. 动态库文件: ${DYLIB_OUT}"
echo "2. 配置文件:   ${SCRIPT_DIR}/${OUTPUT_NAME}.plist"
echo "3. 越狱deb包:  ${DEB_FILE}"
echo "4. 通用zip包:  ${ZIP_FILE}"
echo ""
echo "导入指引："
echo "• 无论是 LiveContainer 还是 Gnoix，在「插件管理」直接导入 .deb、.zip 或 .dylib 均可立即生效！"
echo "======================================================="
