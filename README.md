# 🎬 FastRecord - macOS 屏幕录制应用

FastRecord 是一款简洁高效的 macOS 屏幕录制工具，专为快速录制和分享而设计。基于原生 ScreenCaptureKit 框架构建，提供流畅的录制体验和高质量输出。

## ✨ 功能特性

### 🎥 屏幕录制
- **全屏录制** - 录制整个屏幕，原生分辨率
- **区域选择录制** - 类似 macOS 截图工具的拖拽选择
- **高质量输出** - 使用 H.264 编码，保存为 MP4 格式
- **实时状态显示** - 录制时长和状态指示器

### 📷 摄像头叠加层
- **圆形摄像头蒙版** - 带白色边框的圆形摄像头画面
- **多位置选择** - 支持左上、右上、左下、右下四个位置
- **三种尺寸** - 小(120x120)、中(180x180)、大(240x240)
- **实时合成** - 摄像头画面实时叠加到屏幕录制中

### 🎤 音频录制
- **麦克风录制** - 可选启用/禁用麦克风输入
- **系统音频** - 支持录制系统音频（需配置）

### 🔒 权限管理
- **自动权限检查** - 启动时检查所有必要权限
- **智能权限请求** - 使用系统屏幕录制授权 API 请求权限，缺少权限时引导用户授权
- **macOS 26 适配** - 使用签名 `.app` 包身份申请「屏幕与系统音频录制」权限，避免裸可执行文件不显示在系统设置列表中
- **权限状态显示** - 实时显示权限授权状态

### 🖱️ 用户界面
- **菜单栏应用** - 轻量级菜单栏图标
- **现代 UI** - SwiftUI 构建的简洁界面
- **状态指示** - 录制中显示红色圆点
- **一键退出** - 内置退出按钮

## 🚀 快速开始

### 系统要求
- macOS 13.0 或更高版本（已适配 macOS 26 Tahoe）
- 支持 Intel 和 Apple Silicon Mac
- 4GB 内存（建议 8GB 以获得最佳性能）

### 安装方法

#### 方法一：下载预编译版本
1. 从项目页面下载最新的 DMG 文件
2. 打开 DMG 文件，将 FastRecord 拖入应用程序文件夹
3. 首次打开时，右键点击并选择「打开」

#### 方法二：从源码构建
```bash
# 克隆项目
git clone https://github.com/nolangz/FastRecord.git
cd FastRecord

# 构建并打包为 .app/.dmg（macOS 26 推荐方式）
./create_fastrecord_dmg.sh

# 安装后从 /Applications 启动 FastRecord.app
open /Applications/FastRecord.app
```


## 📱 使用方法

1. **启动应用** - 运行后在菜单栏会出现摄像机图标
2. **点击图标** - 查看录制选项和权限状态
3. **选择录制模式**：
   - 点击「全屏录制」开始全屏录制
   - 点击「选择区域」拖拽选择录制区域
4. **配置设置**：
   - 启用/禁用麦克风
   - 启用/禁用系统音频
   - 启用/禁用摄像头叠加层
   - 选择摄像头位置和尺寸
5. **停止录制** - 录制过程中点击「停止录制」
6. **查看文件** - 录制完成的视频文件自动保存到桌面，文件名格式：`FastRecord_YYYY-MM-DD_HH-MM-SS.mp4`

## 🏗️ 技术架构

### 核心技术
- **ScreenCaptureKit** - macOS 原生屏幕录制 API
- **SwiftUI** - 现代 UI 框架
- **AVFoundation** - 音频录制和视频编码
- **Core Image** - 摄像头圆形蒙版处理

### 项目结构
```
FastRecord/
├── ScreenRecorder/
│   ├── App/               # 应用入口和生命周期
│   ├── Core/
│   │   ├── Recording/     # 屏幕录制核心
│   │   ├── Camera/        # 摄像头处理
│   │   ├── Audio/         # 音频录制
│   │   └── Permissions/   # 权限管理
│   ├── UI/
│   │   └── MenuBar/       # 菜单栏界面
│   └── Models/            # 数据模型
└── Resources/             # 应用资源文件
```

### 关键优势
- **零配置启动** - 开箱即用，无需复杂设置
- **高性能录制** - 支持最高 60fps 录制
- **低系统资源** - CPU 占用率低于 10%
- **实时合成** - 摄像头画面无延迟叠加
- **原生体验** - 完全基于 macOS 原生框架

## 🔧 开发指南

### 环境配置
- Xcode 15.0+（macOS 26 建议使用 Xcode 26 或更新版本构建）
- Swift 5.9+
- macOS SDK 13.0+

### 核心组件
- `ScreenRecorder` - 屏幕录制引擎
- `CameraManager` - 摄像头管理器
- `AudioManager` - 音频处理模块
- `PermissionsManager` - 权限管理器
- `StatusBarController` - 菜单栏控制器

## 📄 许可证

MIT License - 详见 [LICENSE](LICENSE) 文件

## 🤝 贡献指南

欢迎贡献代码！请遵循以下步骤：

1. Fork 本仓库
2. 创建功能分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 创建 Pull Request

## 🐛 问题反馈

如果遇到问题，请在 [Issues](https://github.com/nolangz/FastRecord/issues) 页面提交。

## 👨‍💻 作者

- **Nolan Lai** - [GitHub](https://github.com/nolangz)

## 🙏 致谢

- 感谢 Apple 提供的 ScreenCaptureKit 框架
- 感谢所有贡献者和用户的支持

---

**FastRecord** - 让屏幕录制变得简单 🎬

## 🍎 macOS 26 Tahoe 兼容说明

- macOS 26 的隐私设置将屏幕录制相关项目展示为「屏幕与系统音频录制」。FastRecord 现在通过 CoreGraphics 授权 API 触发系统权限流程，并在未授权时跳转到对应设置页。
- 请使用 `./create_fastrecord_dmg.sh` 生成并安装 `FastRecord.app`。不要直接运行 `.build/release/FastRecord` 裸可执行文件；macOS 26.1 及更新版本可能不会把裸可执行文件稳定显示在权限列表中。
- 发布给其他用户时建议设置稳定的 Developer ID 签名：`CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./create_fastrecord_dmg.sh`。未设置时脚本会使用 ad-hoc 签名，仅适合本机测试。
