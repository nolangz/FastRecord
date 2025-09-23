import Cocoa

// 简单的命令行入口点
print("🚀 启动 ScreenRecorder...")
print("📍 工作目录: \(FileManager.default.currentDirectoryPath)")
print("🏠 用户目录: \(NSHomeDirectory())")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

print("✅ 应用初始化完成，开始运行...")
app.run()