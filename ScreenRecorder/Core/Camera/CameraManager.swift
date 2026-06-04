import Foundation
import AVFoundation
import CoreImage

struct CameraDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
class CameraManager: NSObject, ObservableObject {
    @Published var isAvailable = false
    @Published var isCapturing = false
    @Published var availableCameras: [CameraDevice] = []
    @Published var selectedCameraID = ""
    
    private var captureSession: AVCaptureSession?
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var outputQueue = DispatchQueue(label: "cameraQueue", qos: .userInteractive)
    
    private var currentPixelBuffer: CVPixelBuffer?
    private let ciContext = CIContext()
    
    override init() {
        super.init()
        refreshCameraDevices()
    }
    
    // MARK: - 检查摄像头可用性
    func checkCameraAvailability() {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let hasCamera = !discoverCaptureDevices().isEmpty

        isAvailable = (authStatus == .authorized) && hasCamera
        print("📷 摄像头可用性: \(isAvailable) (权限: \(authStatus.rawValue), 设备: \(hasCamera))")
    }

    func refreshCameraDevices() {
        let devices = discoverCaptureDevices()
        availableCameras = devices.map { device in
            CameraDevice(id: device.uniqueID, name: device.localizedName)
        }

        if selectedCameraID.isEmpty || !availableCameras.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = availableCameras.first?.id ?? ""
        }

        checkCameraAvailability()
        print("📷 找到 \(availableCameras.count) 个摄像头设备")
    }

    var selectedCameraName: String {
        availableCameras.first(where: { $0.id == selectedCameraID })?.name ?? "无可用摄像头"
    }
    
    // MARK: - 开始摄像头捕获
    func startCapture() async throws {
        guard isAvailable && !isCapturing else { return }
        
        print("📷 启动摄像头捕获...")
        
        // 创建捕获会话
        captureSession = AVCaptureSession()
        guard let session = captureSession else {
            throw CameraError.sessionCreationFailed
        }
        
        session.beginConfiguration()
        
        // 设置捕获质量
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        
        // 获取选中的摄像头
        videoDevice = selectedCaptureDevice()

        guard let device = videoDevice else {
            throw CameraError.deviceNotFound
        }

        configurePreferredFormat(for: device)
        
        // 创建输入
        videoInput = try AVCaptureDeviceInput(device: device)
        guard let input = videoInput else {
            throw CameraError.inputCreationFailed
        }
        
        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            throw CameraError.cannotAddInput
        }
        
        // 创建输出
        videoOutput = AVCaptureVideoDataOutput()
        guard let output = videoOutput else {
            throw CameraError.outputCreationFailed
        }
        
        output.setSampleBufferDelegate(self, queue: outputQueue)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            throw CameraError.cannotAddOutput
        }
        
        session.commitConfiguration()
        session.startRunning()
        
        isCapturing = true
        print("✅ 摄像头捕获已启动: \(device.localizedName)")
    }
    
    // MARK: - 停止摄像头捕获
    func stopCapture() {
        print("📷 停止摄像头捕获...")
        
        captureSession?.stopRunning()
        captureSession = nil
        videoDevice = nil
        videoInput = nil
        videoOutput = nil
        currentPixelBuffer = nil
        
        isCapturing = false
        print("✅ 摄像头捕获已停止")
    }
    
    // MARK: - 获取当前摄像头画面
    func getCurrentFrame() -> CVPixelBuffer? {
        return currentPixelBuffer
    }

    var currentFrameAspectRatio: CGFloat? {
        guard let currentPixelBuffer else { return nil }

        let width = CVPixelBufferGetWidth(currentPixelBuffer)
        let height = CVPixelBufferGetHeight(currentPixelBuffer)

        guard width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }

    private func selectedCaptureDevice() -> AVCaptureDevice? {
        let devices = discoverCaptureDevices()

        if let device = devices.first(where: { $0.uniqueID == selectedCameraID }) {
            return device
        }

        return devices.first(where: { $0.position == .front }) ?? devices.first
    }

    private func discoverCaptureDevices() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]

        if #available(macOS 14.0, *) {
            deviceTypes = [.builtInWideAngleCamera, .external]
        } else {
            deviceTypes = [.builtInWideAngleCamera, .externalUnknown]
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private func configurePreferredFormat(for device: AVCaptureDevice) {
        let preferredAspectRatio: CGFloat = 16.0 / 9.0
        let targetPixels = 1920 * 1080

        let candidates = device.formats.compactMap { format -> (format: AVCaptureDevice.Format, width: Int32, height: Int32, aspectRatio: CGFloat, pixelCount: Int)? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width > 0, dimensions.height > 0 else { return nil }

            let aspectRatio = CGFloat(dimensions.width) / CGFloat(dimensions.height)
            return (
                format: format,
                width: dimensions.width,
                height: dimensions.height,
                aspectRatio: aspectRatio,
                pixelCount: Int(dimensions.width * dimensions.height)
            )
        }

        guard let bestFormat = candidates.min(by: { lhs, rhs in
            let lhsAspectScore = abs(lhs.aspectRatio - preferredAspectRatio)
            let rhsAspectScore = abs(rhs.aspectRatio - preferredAspectRatio)

            if abs(lhsAspectScore - rhsAspectScore) > 0.01 {
                return lhsAspectScore < rhsAspectScore
            }

            let lhsResolutionScore = abs(lhs.pixelCount - targetPixels)
            let rhsResolutionScore = abs(rhs.pixelCount - targetPixels)
            return lhsResolutionScore < rhsResolutionScore
        }) else {
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = bestFormat.format

            let supports30FPS = bestFormat.format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= 30 && range.maxFrameRate >= 30
            }

            if supports30FPS {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            }

            device.unlockForConfiguration()
            print("📷 使用摄像头格式: \(bestFormat.width)x\(bestFormat.height)")
        } catch {
            print("⚠️  摄像头格式配置失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - 创建圆形蒙版摄像头画面
    func createCircularCameraOverlay(size: CGSize) -> CIImage? {
        guard let pixelBuffer = currentPixelBuffer else { 
            print("⚠️  摄像头当前帧为空")
            return nil 
        }
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // 计算缩放比例以适应目标尺寸
        let inputSize = ciImage.extent.size
        let scale = min(size.width / inputSize.width, size.height / inputSize.height)
        
        // 缩放图像
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        // 创建圆形裁剪蒙版
        let radius = min(size.width, size.height) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        
        // 简化的圆形蒙版实现
        
        // 使用自定义圆形蒙版
        let maskImage = createCircularMask(size: size, center: center, radius: radius)
        
        // 应用蒙版
        let maskedImage = scaledImage.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: maskImage
        ])
        
        // 添加白色边框
        let borderImage = createCircularBorder(size: size, center: center, radius: radius, borderWidth: 2.0)
        let finalImage = maskedImage.composited(over: borderImage)
        
        return finalImage
    }
    
    // MARK: - 创建圆形蒙版
    private func createCircularMask(size: CGSize, center: CGPoint, radius: CGFloat) -> CIImage {
        // 创建径向渐变作为蒙版
        guard let gradient = CIFilter(name: "CIRadialGradient") else {
            return CIImage.empty()
        }
        
        gradient.setValue(CIVector(x: center.x, y: center.y), forKey: "inputCenter")
        gradient.setValue(radius - 1, forKey: "inputRadius0")
        gradient.setValue(radius, forKey: "inputRadius1")
        gradient.setValue(CIColor.white, forKey: "inputColor0")
        gradient.setValue(CIColor.clear, forKey: "inputColor1")
        
        return gradient.outputImage?.cropped(to: CGRect(origin: .zero, size: size)) ?? CIImage.empty()
    }
    
    // MARK: - 创建圆形边框
    private func createCircularBorder(size: CGSize, center: CGPoint, radius: CGFloat, borderWidth: CGFloat) -> CIImage {
        // 简化边框实现 - 创建白色圆形背景
        guard let borderFilter = CIFilter(name: "CIRadialGradient") else {
            return CIImage.empty()
        }
        
        borderFilter.setValue(CIVector(x: center.x, y: center.y), forKey: "inputCenter")
        borderFilter.setValue(radius - borderWidth, forKey: "inputRadius0")
        borderFilter.setValue(radius, forKey: "inputRadius1")
        borderFilter.setValue(CIColor.white, forKey: "inputColor0")
        borderFilter.setValue(CIColor.clear, forKey: "inputColor1")
        
        return borderFilter.outputImage?.cropped(to: CGRect(origin: .zero, size: size)) ?? CIImage.empty()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // 更新当前帧
        Task { @MainActor in
            currentPixelBuffer = pixelBuffer
        }
    }
}

// MARK: - 错误类型
enum CameraError: Error, LocalizedError {
    case sessionCreationFailed
    case deviceNotFound
    case inputCreationFailed
    case outputCreationFailed
    case cannotAddInput
    case cannotAddOutput
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed:
            return "创建摄像头会话失败"
        case .deviceNotFound:
            return "未找到摄像头设备"
        case .inputCreationFailed:
            return "创建摄像头输入失败"
        case .outputCreationFailed:
            return "创建摄像头输出失败"
        case .cannotAddInput:
            return "无法添加摄像头输入"
        case .cannotAddOutput:
            return "无法添加摄像头输出"
        case .permissionDenied:
            return "摄像头权限被拒绝"
        }
    }
}
