import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController!
    var permissionsManager: PermissionsManager!
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("🚀 FastRecord 启动中...")

        // 隐藏 Dock 图标，只保留菜单栏。macOS 26 对菜单栏项目身份更敏感，
        // 在创建 NSStatusItem 前先设置为 accessory，确保以应用包身份注册。
        NSApp.setActivationPolicy(.accessory)

        // 初始化权限管理器
        permissionsManager = PermissionsManager()

        // 初始化状态栏控制器，并在创建 SwiftUI 菜单前注入权限管理器。
        statusBar = StatusBarController(permissionsManager: permissionsManager)

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