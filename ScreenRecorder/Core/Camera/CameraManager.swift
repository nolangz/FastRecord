import Foundation
import AVFoundation
import CoreImage

@MainActor
class CameraManager: NSObject, ObservableObject {
    @Published var isAvailable = false
    @Published var isCapturing = false
    
    private var captureSession: AVCaptureSession?
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var outputQueue = DispatchQueue(label: "cameraQueue", qos: .userInteractive)
    
    private var currentPixelBuffer: CVPixelBuffer?
    private let ciContext = CIContext()
    
    override init() {
        super.init()
        checkCameraAvailability()
    }
    
    // MARK: - 检查摄像头可用性
    func checkCameraAvailability() {
        Task { @MainActor in
            let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
            let hasCamera = !AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera],
                mediaType: .video,
                position: .front
            ).devices.isEmpty
            
            isAvailable = (authStatus == .authorized) && hasCamera
            print("📷 摄像头可用性: \(isAvailable) (权限: \(authStatus.rawValue), 设备: \(hasCamera))")
        }
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
        
        // 获取前置摄像头
        videoDevice = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        ).devices.first
        
        guard let device = videoDevice else {
            throw CameraError.deviceNotFound
        }
        
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
        print("✅ 摄像头捕获已启动")
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