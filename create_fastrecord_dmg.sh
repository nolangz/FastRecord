#!/bin/bash
set -euo pipefail

APP_NAME="FastRecord"
APP_VERSION="1.0"
BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-com.nolangz.fastrecord}"
DMG_NAME="${APP_NAME}-v${APP_VERSION}.dmg"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

cat <<MSG
🔨 开始创建 ${APP_NAME} DMG 包...
📦 Bundle ID: ${BUNDLE_ID}
🖥️  目标兼容: macOS 13.0+（已适配 macOS 26 Tahoe 权限与菜单栏行为）
MSG

# macOS 26 的屏幕录制 TCC 列表不再可靠展示裸可执行文件。
# 始终构建 .app 包，并对整个包签名，确保权限记录绑定到稳定的应用身份。
echo "🏗️  构建 release 可执行文件..."
swift build -c release

# 清理之前的构建
rm -rf dist/
mkdir -p dist

# 创建应用目录结构
echo "📁 创建应用包结构..."
mkdir -p "dist/${APP_NAME}.app/Contents/MacOS"
mkdir -p "dist/${APP_NAME}.app/Contents/Resources"

# 复制可执行文件
echo "📋 复制可执行文件..."
cp ".build/release/${APP_NAME}" "dist/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

# 复制应用图标
echo "🎨 复制应用图标..."
cp ScreenRecorder/Resources/AppIcon.icns "dist/${APP_NAME}.app/Contents/Resources/"

# 创建 Info.plist
echo "📝 创建 Info.plist..."
cat > "dist/${APP_NAME}.app/Contents/Info.plist" << EOF_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>FastRecord 需要访问麦克风来录制您的语音。</string>
    <key>NSCameraUsageDescription</key>
    <string>FastRecord 需要访问摄像头来添加摄像头叠加画面。</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>FastRecord 需要录制系统音频，以便把应用和系统声音保存到屏幕录制文件中。</string>
</dict>
</plist>
EOF_PLIST

# 设置可执行权限
echo "🔐 设置可执行权限..."
chmod +x "dist/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

# 对应用包签名。发布时建议导出 CODESIGN_IDENTITY="Developer ID Application: ..."；
# 未配置时使用 ad-hoc 签名，便于本地测试，但重新构建后可能需要重新授权 TCC 权限。
echo "✍️  签名应用包..."
if [ "${CODESIGN_IDENTITY}" = "-" ]; then
    echo "⚠️  未设置 CODESIGN_IDENTITY，使用 ad-hoc 签名；macOS 26 上重新构建后可能需要重新授权屏幕录制权限。"
    codesign --force --deep --sign - "dist/${APP_NAME}.app"
else
    codesign --force --deep --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" "dist/${APP_NAME}.app"
fi
codesign --verify --deep --strict --verbose=2 "dist/${APP_NAME}.app"

# 复制用户指南
echo "📄 复制用户指南..."
cp "FastRecord 使用指南.txt" dist/

# 创建 Applications 快捷方式的符号链接
echo "🔗 创建 Applications 快捷方式..."
ln -s /Applications dist/Applications

# 创建 DMG
echo "💿 创建 DMG 文件..."

# 如果 DMG 已存在则删除
if [ -f "${DMG_NAME}" ]; then
    rm "${DMG_NAME}"
fi

# 创建临时 DMG
hdiutil create -volname "${APP_NAME}" -srcfolder dist -ov -format UDZO "${DMG_NAME}"

# 清理临时文件
echo "🧹 清理临时文件..."
rm -rf dist/

echo "✅ DMG 创建完成: ${DMG_NAME}"
echo ""
echo "📦 DMG 包含以下内容:"
echo "   - ${APP_NAME}.app (主应用，带应用图标，已签名)"
echo "   - FastRecord 使用指南.txt (使用说明)"
echo "   - Applications 文件夹快捷方式 (便于安装)"
echo ""
echo "🎯 安装方式:"
echo "   1. 双击打开 DMG 文件"
echo "   2. 将 ${APP_NAME}.app 拖拽到 Applications 文件夹"
echo "   3. 阅读使用指南了解 macOS 26 权限设置和使用方法"
echo "   4. 录制的视频文件会保存到桌面"
echo ""
echo "🚀 FastRecord - 快速屏幕录制工具！"
