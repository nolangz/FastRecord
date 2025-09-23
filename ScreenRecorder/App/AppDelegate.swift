import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController!
    var permissionsManager: PermissionsManager!
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("🚀 FastRecord 启动中...")

        // 初始化权限管理器
        permissionsManager = PermissionsManager()

        // 初始化状态栏控制器
        statusBar = StatusBarController()
        statusBar.permissionsManager = permissionsManager

        // 隐藏dock图标，只保留菜单栏
        NSApp.setActivationPolicy(.accessory)

        // 应用启动时自动展开菜单，让用户知道这是个菜单栏应用
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.statusBar.showMenu()
            print("📱 自动展开菜单栏，提示用户这是菜单栏应用")
        }

        print("✅ FastRecord 启动完成")
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        print("👋 FastRecord 退出")
    }
}