import Foundation
import AVFoundation
import ScreenCaptureKit

@MainActor
class PermissionsManager: ObservableObject {
    @Published var screenRecordingAuthorized = false
    @Published var microphoneAuthorized = false
    @Published var cameraAuthorized = false
    
    @Published var isCheckingPermissions = false
    
    init() {
        Task {
            await checkAllPermissions()
        }
    }
    
    // MARK: - 检查所有权限状态
    func checkAllPermissions() async {
        print("🔐 检查所有权限状态...")
        isCheckingPermissions = true
        
        await checkScreenRecordingPermission()
        await checkMicrophonePermission()
        await checkCameraPermission()
        
        isCheckingPermissions = false
        print("✅ 权限检查完成 - 屏幕:\(screenRecordingAuthorized) 麦克风:\(microphoneAuthorized) 摄像头:\(cameraAuthorized)")
    }
    
    // MARK: - 屏幕录制权限
    func checkScreenRecordingPermission() async {
        if #available(macOS 12.3, *) {
            do {
                // 尝试获取屏幕内容来检查权限
                let availableContent = try await SCShareableContent.excludingDesktopWindows(
                    false, 
                    onScreenWindowsOnly: true
                )
                screenRecordingAuthorized = !availableContent.displays.isEmpty
                print("📺 屏幕录制权限: \(screenRecordingAuthorized ? "已授权" : "未授权")")
                
                if screenRecordingAuthorized {
                    print("📺 发现 \(availableContent.displays.count) 个显示器")
                    for (index, display) in availableContent.displays.enumerated() {
                        print("   显示器 \(index + 1): \(display.width)x\(display.height)")
                    }
                } else {
                    print("⚠️  无法获取显示器信息，可能权限未授权")
                }
            } catch {
                screenRecordingAuthorized = false
                print("❌ 屏幕录制权限检查失败: \(error.localizedDescription)")
            }
        } else {
            screenRecordingAuthorized = false
            print("⚠️  系统版本过低，不支持ScreenCaptureKit")
        }
    }
    
    func requestScreenRecordingPermission() async {
        print("📺 请求屏幕录制权限...")
        await checkScreenRecordingPermission()
        
        if !screenRecordingAuthorized {
            // 如果权限未授权，引导用户到系统设置
            openScreenRecordingSettings()
        }
    }
    
    private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
        print("🔗 已打开系统设置 - 屏幕录制权限")
    }
    
    // MARK: - 麦克风权限
    func checkMicrophonePermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneAuthorized = (status == .authorized)
        print("🎤 麦克风权限: \(status == .authorized ? "已授权" : "未授权")")
    }
    
    func requestMicrophonePermission() async {
        print("🎤 请求麦克风权限...")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneAuthorized = granted
        print("🎤 麦克风权限请求结果: \(granted ? "已授权" : "被拒绝")")
    }
    
    // MARK: - 摄像头权限
    func checkCameraPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAuthorized = (status == .authorized)
        print("📷 摄像头权限: \(status == .authorized ? "已授权" : "未授权")")
    }
    
    func requestCameraPermission() async {
        print("📷 请求摄像头权限...")
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        cameraAuthorized = granted
        print("📷 摄像头权限请求结果: \(granted ? "已授权" : "被拒绝")")
    }
    
    // MARK: - 工具方法
    var allPermissionsGranted: Bool {
        return screenRecordingAuthorized && microphoneAuthorized && cameraAuthorized
    }
    
    var essentialPermissionsGranted: Bool {
        return screenRecordingAuthorized
    }
    
    func requestAllPermissions() async {
        print("🔐 请求所有权限...")
        await requestScreenRecordingPermission()
        await requestMicrophonePermission() 
        await requestCameraPermission()
    }
}