import Cocoa
import SwiftUI
import AVFoundation

@MainActor
class CircularCameraWindow: NSObject {
    private var cameraWindow: NSWindow?
    private let cameraManager: CameraManager
    private var cameraSize: CameraOverlaySize = .medium
    private var cameraShape: CameraOverlayShape = .circle
    private let fallbackCameraAspectRatio: CGFloat = 16.0 / 9.0
    
    init(cameraManager: CameraManager) {
        self.cameraManager = cameraManager
        super.init()
    }

    var currentWindowSize: NSSize {
        cameraWindow?.frame.size ?? NSSize(width: CameraOverlaySize.medium.size.width, height: CameraOverlaySize.medium.size.height)
    }
    
    func show(at position: CameraOverlayPosition, size: CameraOverlaySize, shape: CameraOverlayShape, recordingRect: CGRect? = nil) {
        print("🎥 显示摄像头窗口: \(shape.displayName)...")
        cameraSize = size
        cameraShape = shape
        
        // 如果窗口已存在，先关闭
        hide()
        
        // 计算窗口位置和大小
        let windowSize = overlayWindowSize(for: size, shape: shape)
        let windowOrigin = calculateWindowOrigin(for: position, windowSize: windowSize, recordingRect: recordingRect)
        let windowRect = NSRect(origin: windowOrigin, size: windowSize)
        
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
        
        // 创建摄像头视图
        let contentView = NSHostingView(
            rootView: CameraOverlayView(cameraManager: cameraManager, windowController: self, shape: shape)
                .frame(width: windowSize.width, height: windowSize.height)
        )
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = contentView
        
        // 显示窗口
        window.orderFrontRegardless()
        
        print("✅ 摄像头窗口已显示 - 位置: \(position), 大小: \(windowSize), 形状: \(shape.displayName)")
    }
    
    func hide() {
        print("🎥 隐藏圆形摄像头窗口...")
        cameraWindow?.close()
        cameraWindow = nil
    }
    
    func resizeWindow(to size: CameraOverlaySize) {
        guard let window = cameraWindow else { return }
        
        print("🔄 调整摄像头窗口大小为: \(size)")
        cameraSize = size
        
        let newSize = overlayWindowSize(for: size, shape: cameraShape)
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
            rootView: CameraOverlayView(cameraManager: cameraManager, windowController: self, shape: cameraShape)
                .frame(width: newSize.width, height: newSize.height)
        )
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = contentView
    }

    func updateShape(to shape: CameraOverlayShape) {
        guard let window = cameraWindow else { return }

        print("🔄 调整摄像头窗口形状为: \(shape.displayName)")
        cameraShape = shape

        let currentFrame = window.frame
        let newSize = overlayWindowSize(for: cameraSize, shape: shape)
        let newOrigin = NSPoint(
            x: currentFrame.midX - newSize.width / 2,
            y: currentFrame.midY - newSize.height / 2
        )
        window.setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: true)

        let contentView = NSHostingView(
            rootView: CameraOverlayView(cameraManager: cameraManager, windowController: self, shape: shape)
                .frame(width: newSize.width, height: newSize.height)
        )
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = contentView
    }

    func updateAspectRatioIfNeeded(to aspectRatio: CGFloat) {
        guard cameraShape == .roundedSquare, let window = cameraWindow else { return }

        let newSize = overlayWindowSize(for: cameraSize, shape: cameraShape, aspectRatio: aspectRatio)
        let currentSize = window.frame.size
        let currentAspect = currentSize.width / max(currentSize.height, 1)
        let expectedAspect = newSize.width / max(newSize.height, 1)

        guard abs(currentAspect - expectedAspect) > 0.03 else { return }

        let currentFrame = window.frame
        let newOrigin = NSPoint(
            x: currentFrame.midX - newSize.width / 2,
            y: currentFrame.midY - newSize.height / 2
        )
        window.setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: false)

        let contentView = NSHostingView(
            rootView: CameraOverlayView(cameraManager: cameraManager, windowController: self, shape: cameraShape)
                .frame(width: newSize.width, height: newSize.height)
        )
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = contentView
    }

    private func overlayWindowSize(for size: CameraOverlaySize, shape: CameraOverlayShape, aspectRatio: CGFloat? = nil) -> NSSize {
        let baseSide = size.size.width

        guard shape == .roundedSquare else {
            return NSSize(width: baseSide, height: baseSide)
        }

        let rawAspectRatio = aspectRatio ?? cameraManager.currentFrameAspectRatio ?? fallbackCameraAspectRatio
        let cameraAspectRatio = min(max(rawAspectRatio, 0.75), 2.20)

        if cameraAspectRatio >= 1 {
            return NSSize(width: round(baseSide * cameraAspectRatio), height: baseSide)
        } else {
            return NSSize(width: baseSide, height: round(baseSide / cameraAspectRatio))
        }
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

// MARK: - 摄像头叠加视图
struct CameraOverlayView: View {
    @ObservedObject var cameraManager: CameraManager
    weak var windowController: CircularCameraWindow?
    let shape: CameraOverlayShape
    @State private var updateTimer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect() // 30fps
    @State private var currentImage: NSImage?
    @State private var showSizeMenu = false

    private let overlayPadding: CGFloat = 6

    private var roundedSquareShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: roundedSquareCornerRadius, style: .continuous)
    }

    private var roundedSquareCornerRadius: CGFloat {
        guard shape == .roundedSquare else { return 0 }

        let side = currentWindowMinSide
        return max(24, side * 0.16)
    }

    private var currentWindowMinSide: CGFloat {
        let windowSize = windowController?.currentWindowSize ?? NSSize(width: CameraOverlaySize.medium.size.width, height: CameraOverlaySize.medium.size.height)
        return min(windowSize.width, windowSize.height)
    }
    
    var body: some View {
        ZStack {
            // 透明背景
            Color.clear
            
            // 摄像头画面 - 添加padding确保边框完整显示
            if let image = currentImage {
                cameraImageView(image)
            } else {
                placeholderView
            }
            
            // 右键菜单提示
            contextMenuHitArea
        }
        .onReceive(updateTimer) { _ in
            updateCameraImage()
        }
    }

    @ViewBuilder
    private func cameraImageView(_ image: NSImage) -> some View {
        switch shape {
        case .circle:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: 3)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 2)
                )
                .padding(4)
        case .roundedSquare:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(roundedSquareShape)
                .overlay(roundedSquareInnerStroke)
                .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 4)
                .padding(overlayPadding)
        }
    }

    @ViewBuilder
    private var placeholderView: some View {
        switch shape {
        case .circle:
            Circle()
                .fill(Color.black)
                .overlay(placeholderContent)
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: 3)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 2)
                )
                .padding(4)
        case .roundedSquare:
            roundedSquareShape
                .fill(Color.black)
                .overlay(placeholderContent)
                .overlay(roundedSquareInnerStroke)
                .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 4)
                .padding(overlayPadding)
        }
    }

    private var placeholderContent: some View {
        VStack {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
                .foregroundColor(.gray)
            Text("摄像头")
                .foregroundColor(.gray)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var contextMenuHitArea: some View {
        switch shape {
        case .circle:
            Circle()
                .fill(Color.clear)
                .contentShape(Circle())
                .cameraContextMenu(windowController: windowController)
                .padding(4)
        case .roundedSquare:
            roundedSquareShape
                .fill(Color.clear)
                .contentShape(roundedSquareShape)
                .cameraContextMenu(windowController: windowController)
                .padding(overlayPadding)
        }
    }

    private var roundedSquareInnerStroke: some View {
        roundedSquareShape
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
    }
    
    private func updateCameraImage() {
        guard cameraManager.isCapturing,
              let pixelBuffer = cameraManager.getCurrentFrame() else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let cropRect = shape == .roundedSquare ? visibleContentRect(in: pixelBuffer, imageExtent: ciImage.extent) : ciImage.extent

        if shape == .roundedSquare {
            let aspectRatio = cropRect.width / max(cropRect.height, 1)
            if aspectRatio.isFinite, aspectRatio > 0 {
                windowController?.updateAspectRatioIfNeeded(to: aspectRatio)
            }
        }
        
        // 转换CVPixelBuffer到NSImage
        let context = CIContext()
        let sourceImage = ciImage.cropped(to: cropRect)
        let normalizedImage = sourceImage.transformed(
            by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
        )
        let normalizedExtent = CGRect(origin: .zero, size: cropRect.size)

        // 镜像翻转图像（前置摄像头需要）
        let flippedImage = normalizedImage.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        let translatedImage = flippedImage.transformed(by: CGAffineTransform(translationX: normalizedExtent.width, y: 0))
        
        if let cgImage = context.createCGImage(translatedImage, from: normalizedExtent) {
            currentImage = NSImage(cgImage: cgImage, size: normalizedExtent.size)
        }
    }

    private func visibleContentRect(in pixelBuffer: CVPixelBuffer, imageExtent: CGRect) -> CGRect {
        guard let detectedRect = detectNonBlackContentRect(in: pixelBuffer) else {
            return imageExtent
        }

        let horizontalTrim = detectedRect.minX + imageExtent.width - detectedRect.maxX
        let verticalTrim = detectedRect.minY + imageExtent.height - detectedRect.maxY
        let hasMeaningfulTrim = horizontalTrim > imageExtent.width * 0.04 || verticalTrim > imageExtent.height * 0.04

        guard hasMeaningfulTrim else {
            return imageExtent
        }

        return detectedRect.intersection(imageExtent)
    }

    private func detectNonBlackContentRect(in pixelBuffer: CVPixelBuffer) -> CGRect? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width > 0, height > 0 else { return nil }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let sampleStep = max(1, min(width, height) / 120)
        let brightnessThreshold = 18
        let minimumBrightSampleRatio = 0.02

        func isBrightPixel(x: Int, y: Int) -> Bool {
            let offset = y * bytesPerRow + x * 4
            let blue = Int(bytes[offset])
            let green = Int(bytes[offset + 1])
            let red = Int(bytes[offset + 2])
            return max(red, green, blue) > brightnessThreshold
        }

        func rowHasContent(_ y: Int) -> Bool {
            var brightSamples = 0
            var totalSamples = 0

            for x in stride(from: 0, to: width, by: sampleStep) {
                totalSamples += 1
                if isBrightPixel(x: x, y: y) {
                    brightSamples += 1
                }
            }

            guard totalSamples > 0 else { return false }
            return Double(brightSamples) / Double(totalSamples) > minimumBrightSampleRatio
        }

        func columnHasContent(_ x: Int, top: Int, bottom: Int) -> Bool {
            var brightSamples = 0
            var totalSamples = 0

            for y in stride(from: top, through: bottom, by: sampleStep) {
                totalSamples += 1
                if isBrightPixel(x: x, y: y) {
                    brightSamples += 1
                }
            }

            guard totalSamples > 0 else { return false }
            return Double(brightSamples) / Double(totalSamples) > minimumBrightSampleRatio
        }

        var top = 0
        while top < height && !rowHasContent(top) {
            top += sampleStep
        }

        var bottom = height - 1
        while bottom > top && !rowHasContent(bottom) {
            bottom -= sampleStep
        }

        guard top < bottom else {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }

        var left = 0
        while left < width && !columnHasContent(left, top: top, bottom: bottom) {
            left += sampleStep
        }

        var right = width - 1
        while right > left && !columnHasContent(right, top: top, bottom: bottom) {
            right -= sampleStep
        }

        guard left < right else {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }

        let minX = max(0, left - sampleStep)
        let minY = max(0, top - sampleStep)
        let maxX = min(width, right + sampleStep + 1)
        let maxY = min(height, bottom + sampleStep + 1)

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private extension View {
    func cameraContextMenu(windowController: CircularCameraWindow?) -> some View {
        self.contextMenu {
            Button("小尺寸") {
                windowController?.resizeWindow(to: .small)
            }
            Button("中等尺寸") {
                windowController?.resizeWindow(to: .medium)
            }
            Button("大尺寸") {
                windowController?.resizeWindow(to: .large)
            }
            Divider()
            Button("圆形") {
                windowController?.updateShape(to: .circle)
            }
            Button("圆角矩形") {
                windowController?.updateShape(to: .roundedSquare)
            }
        }
    }
}
