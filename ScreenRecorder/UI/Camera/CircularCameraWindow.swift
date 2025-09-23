import Cocoa
import SwiftUI
import AVFoundation

@MainActor
class CircularCameraWindow: NSObject {
    private var cameraWindow: NSWindow?
    private let cameraManager: CameraManager
    
    init(cameraManager: CameraManager) {
        self.cameraManager = cameraManager
        super.init()
    }
    
    func show(at position: CameraOverlayPosition, size: CameraOverlaySize, recordingRect: CGRect? = nil) {
        print("🎥 显示圆形摄像头窗口...")
        
        // 如果窗口已存在，先关闭
        hide()
        
        // 计算窗口位置和大小
        let windowSize = size.size
        let windowOrigin = calculateWindowOrigin(for: position, windowSize: NSSize(width: windowSize.width, height: windowSize.height), recordingRect: recordingRect)
        let windowRect = NSRect(origin: windowOrigin, size: NSSize(width: windowSize.width, height: windowSize.height))
        
        // 创建窗口
        cameraWindow = NSWindow(
            contentRect: windowRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        guard let window = cameraWindow else { return }
        
        // 配置窗口 - 使用较低的层级，确保不会覆盖菜单栏popover
        window.level = .floating  // 浮动窗口层级，不会覆盖菜单栏
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = true  // 录制时允许拖拽
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false  // 录制时允许鼠标交互
        window.isReleasedWhenClosed = false
        
        // 创建圆形摄像头视图
        let contentView = NSHostingView(
            rootView: CircularCameraView(cameraManager: cameraManager, windowController: self)
                .frame(width: windowSize.width, height: windowSize.height)
        )
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = contentView
        
        // 显示窗口
        window.orderFrontRegardless()
        
        print("✅ 圆形摄像头窗口已显示 - 位置: \(position), 大小: \(windowSize)")
    }
    
    func hide() {
        print("🎥 隐藏圆形摄像头窗口...")
        cameraWindow?.close()
        cameraWindow = nil
    }
    
    func resizeWindow(to size: CameraOverlaySize) {
        guard let window = cameraWindow else { return }
        
        print("🔄 调整摄像头窗口大小为: \(size)")
        
        let newSize = size.size
        let currentFrame = window.frame
        
        // 保持窗口中心位置不变
        let newOrigin = NSPoint(
            x: currentFrame.midX - newSize.width / 2,
            y: currentFrame.midY - newSize.height / 2
        )
        
        let newFrame = NSRect(origin: newOrigin, size: NSSize(width: newSize.width, height: newSize.height))
        window.setFrame(newFrame, display: true, animate: true)
        
        // 更新内容视图的大小  
        let contentView = NSHostingView(
            rootView: CircularCameraView(cameraManager: cameraManager, windowController: self)
                .frame(width: newSize.width, height: newSize.height)
        )
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = contentView
    }
    
    private func calculateWindowOrigin(for position: CameraOverlayPosition, windowSize: NSSize, recordingRect: CGRect?) -> NSPoint {
        let margin: CGFloat = 20
        
        // 如果是区域录制，基于录制区域定位
        if let recordingRect = recordingRect {
            print("🎯 基于录制区域定位摄像头: \(recordingRect)")
            
            switch position {
            case .topLeft:
                return NSPoint(
                    x: recordingRect.minX + margin,
                    y: recordingRect.maxY - windowSize.height - margin
                )
            case .topRight:
                return NSPoint(
                    x: recordingRect.maxX - windowSize.width - margin,
                    y: recordingRect.maxY - windowSize.height - margin
                )
            case .bottomLeft:
                return NSPoint(
                    x: recordingRect.minX + margin,
                    y: recordingRect.minY + margin
                )
            case .bottomRight:
                return NSPoint(
                    x: recordingRect.maxX - windowSize.width - margin,
                    y: recordingRect.minY + margin
                )
            }
        } else {
            // 全屏录制，基于整个屏幕定位
            guard let screen = NSScreen.main else {
                return NSPoint(x: 100, y: 100)
            }
            
            let screenFrame = screen.frame
            
            switch position {
            case .topLeft:
                return NSPoint(
                    x: screenFrame.minX + margin,
                    y: screenFrame.maxY - windowSize.height - margin - 30  // 留出菜单栏空间
                )
            case .topRight:
                return NSPoint(
                    x: screenFrame.maxX - windowSize.width - margin,
                    y: screenFrame.maxY - windowSize.height - margin - 30
                )
            case .bottomLeft:
                return NSPoint(
                    x: screenFrame.minX + margin,
                    y: screenFrame.minY + margin
                )
            case .bottomRight:
                return NSPoint(
                    x: screenFrame.maxX - windowSize.width - margin,
                    y: screenFrame.minY + margin
                )
            }
        }
    }
}

// MARK: - 圆形摄像头视图
struct CircularCameraView: View {
    @ObservedObject var cameraManager: CameraManager
    weak var windowController: CircularCameraWindow?
    @State private var updateTimer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect() // 30fps
    @State private var currentImage: NSImage?
    @State private var showSizeMenu = false
    
    var body: some View {
        ZStack {
            // 透明背景
            Color.clear
            
            // 圆形摄像头画面 - 添加padding确保边框完整显示
            if let image = currentImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 3)
                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 2)
                    )
                    .padding(4) // 添加padding确保边框不被裁剪
            } else {
                Circle()
                    .fill(Color.black)
                    .overlay(
                        VStack {
                            Image(systemName: "camera.fill")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                            Text("摄像头")
                                .foregroundColor(.gray)
                                .font(.caption)
                        }
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 3)
                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 2)
                    )
                    .padding(4) // 添加padding确保边框不被裁剪
            }
            
            // 右键菜单提示 - 使用Circle作为contentShape
            Circle()
                .fill(Color.clear)
                .contentShape(Circle()) // 改为Circle避免矩形遮挡
                .contextMenu {
                    Button("小尺寸") { 
                        windowController?.resizeWindow(to: .small)
                    }
                    Button("中等尺寸") { 
                        windowController?.resizeWindow(to: .medium)
                    }
                    Button("大尺寸") { 
                        windowController?.resizeWindow(to: .large)
                    }
                }
                .padding(4) // 保持与内容一致的padding
        }
        .onReceive(updateTimer) { _ in
            updateCameraImage()
        }
    }
    
    private func updateCameraImage() {
        guard cameraManager.isCapturing,
              let pixelBuffer = cameraManager.getCurrentFrame() else {
            return
        }
        
        // 转换CVPixelBuffer到NSImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        // 镜像翻转图像（前置摄像头需要）
        let flippedImage = ciImage.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        let translatedImage = flippedImage.transformed(by: CGAffineTransform(translationX: ciImage.extent.width, y: 0))
        
        if let cgImage = context.createCGImage(translatedImage, from: ciImage.extent) {
            currentImage = NSImage(cgImage: cgImage, size: ciImage.extent.size)
        }
    }
}