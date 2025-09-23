#!/bin/bash

echo "🔨 开始创建 FastRecord DMG 包..."

# 清理之前的构建
rm -rf dist/
mkdir -p dist

# 创建应用目录结构
echo "📁 创建应用包结构..."
mkdir -p dist/FastRecord.app/Contents/MacOS
mkdir -p dist/FastRecord.app/Contents/Resources

# 复制可执行文件
echo "📋 复制可执行文件..."
cp .build/release/FastRecord dist/FastRecord.app/Contents/MacOS/FastRecord

# 复制应用图标
echo "🎨 复制应用图标..."
cp ScreenRecorder/Resources/AppIcon.icns dist/FastRecord.app/Contents/Resources/

# 创建 Info.plist
echo "📝 创建 Info.plist..."
cat > dist/FastRecord.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>FastRecord</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.fastrecord</string>
    <key>CFBundleName</key>
    <string>FastRecord</string>
    <key>CFBundleDisplayName</key>
    <string>FastRecord</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
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
    <key>NSMicrophoneUsageDescription</key>
    <string>FastRecord 需要访问麦克风来录制音频。</string>
    <key>NSCameraUsageDescription</key>
    <string>FastRecord 需要访问摄像头来添加视频叠加。</string>
</dict>
</plist>
EOF

# 设置可执行权限
echo "🔐 设置可执行权限..."
chmod +x dist/FastRecord.app/Contents/MacOS/FastRecord

# 复制用户指南
echo "📄 复制用户指南..."
cp "FastRecord 使用指南.txt" dist/

# 创建 Applications 快捷方式的符号链接
echo "🔗 创建 Applications 快捷方式..."
ln -s /Applications dist/Applications

# 创建 DMG
echo "💿 创建 DMG 文件..."
DMG_NAME="FastRecord-v1.0.dmg"

# 如果 DMG 已存在则删除
if [ -f "$DMG_NAME" ]; then
    rm "$DMG_NAME"
fi

# 创建临时 DMG
hdiutil create -volname "FastRecord" -srcfolder dist -ov -format UDZO "$DMG_NAME"

# 清理临时文件
echo "🧹 清理临时文件..."
rm -rf dist/

echo "✅ DMG 创建完成: $DMG_NAME"
echo ""
echo "📦 DMG 包含以下内容:"
echo "   - FastRecord.app (主应用，带应用图标)"
echo "   - FastRecord 使用指南.txt (使用说明)"
echo "   - Applications 文件夹快捷方式 (便于安装)"
echo ""
echo "🎯 安装方式:"
echo "   1. 双击打开 DMG 文件"
echo "   2. 将 FastRecord.app 拖拽到 Applications 文件夹"
echo "   3. 阅读使用指南了解权限设置和使用方法"
echo "   4. 录制的视频文件会保存到桌面"
echo ""
echo "🚀 FastRecord - 快速屏幕录制工具！"