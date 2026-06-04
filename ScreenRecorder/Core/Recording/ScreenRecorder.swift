import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import ScreenCaptureKit

private struct CameraOverlayMetadataFile: Codable {
    let version: Int
    let screenFile: String
    let cameraFile: String?
    let coordinateSpace: String
    let generatedAt: String
    let recordingMode: String
    let recordingRect: CodableRect?
    let samples: [CameraOverlayMetadataSample]
}

private struct CameraOverlayMetadataSample: Codable {
    let time: Double
    let frame: CodableRect
    let shape: String
    let size: String
}

private struct CodableRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
class ScreenRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var canRecord = false
    
    private var stream: SCStream?
    private var videoWriterInput: AVAssetWriterInput?
    private var videoWriter: AVAssetWriter?
    private var pixelBufferAdapter: AVAssetWriterInputPixelBufferAdaptor?

    // 音频录制组件
    private var audioWriterInput: AVAssetWriterInput?
    private var microphoneWriterInput: AVAssetWriterInput?  // macOS 15+ 独立麦克风轨道
    private var avAudioEngineRecorder: AVAudioEngineRecorder?  // AVAudioEngine录制器

    private var recordingStartTime: CMTime = .zero
    private var frameCount: Int64 = 0
    private var audioStartOffset: CMTime? = nil  // 音频开始时间偏移
    private var firstVideoFrameTime: CMTime?  // 记录第一帧视频的时间戳
    
    // 录制配置
    private var outputURL: URL?
    private var recordingRect: CGRect?
    private var isFullScreen: Bool = true
    
    // 音频录制配置
    private var systemAudioEnabled: Bool = false
    private var microphoneEnabled: Bool = false
    private var microphoneDeviceID: String? = nil
    
    // 摄像头叠加层
    private let cameraManager = CameraManager()
    private var enableCameraOverlay = false
    private var cameraOverlayPosition: CameraOverlayPosition = .topRight
    private var cameraOverlaySize: CameraOverlaySize = .medium
    private var cameraOverlaySnapshotProvider: (() -> CameraOverlaySnapshot?)?

    // 独立摄像头视频轨
    private var cameraWriter: AVAssetWriter?
    private var cameraWriterInput: AVAssetWriterInput?
    private var cameraPixelBufferAdapter: AVAssetWriterInputPixelBufferAdaptor?
    private var cameraRecordingTask: Task<Void, Never>?
    private var cameraOutputURL: URL?
    private var overlayMetadataURL: URL?
    private var cameraOutputDimensions: (width: Int, height: Int)?
    private var cameraFrameCount: Int64 = 0
    private var cameraFirstFrameDate: Date?
    private var overlayMetadataStartDate: Date?
    private var overlayMetadataSamples: [CameraOverlayMetadataSample] = []
    private let cameraCIContext = CIContext()
    
    override init() {
        super.init()
        checkCanRecord()
    }
    
    // MARK: - 权限和能力检查
    private func checkCanRecord() {
        Task {
            do {
                // 检查ScreenCaptureKit可用性和权限
                let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                canRecord = !availableContent.displays.isEmpty
                print("📺 ScreenCaptureKit 可用: \(canRecord)")
            } catch {
                canRecord = false
                print("❌ ScreenCaptureKit 检查失败: \(error)")
            }
        }
    }
    
    // MARK: - 设置摄像头叠加层
    func setCameraOverlay(enabled: Bool, position: CameraOverlayPosition, size: CameraOverlaySize) {
        enableCameraOverlay = enabled
        cameraOverlayPosition = position
        cameraOverlaySize = size
    }
    
    // MARK: - 获取摄像头管理器
    func getCameraManager() -> CameraManager {
        return cameraManager
    }

    func setCameraOverlaySnapshotProvider(_ provider: @escaping () -> CameraOverlaySnapshot?) {
        cameraOverlaySnapshotProvider = provider
    }
    
    // MARK: - 录制控制
    func startRecording(
        mode: RecordingMode, 
        outputURL: URL, 
        cameraOverlay: Bool = false, 
        cameraPosition: CameraOverlayPosition = .topRight, 
        cameraSize: CameraOverlaySize = .medium,
        systemAudioEnabled: Bool = false,
        microphoneEnabled: Bool = false,
        microphoneDeviceID: String? = nil
    ) async throws {
        guard canRecord && !isRecording else {
            throw RecordingError.invalidState
        }
        
        print("🎬 开始屏幕录制...")
        
        self.outputURL = outputURL
        self.systemAudioEnabled = systemAudioEnabled
        self.microphoneEnabled = microphoneEnabled
        self.microphoneDeviceID = microphoneDeviceID
        setCameraOverlay(enabled: cameraOverlay, position: cameraPosition, size: cameraSize)
        
        // 启动摄像头（如果需要）
        if enableCameraOverlay {
            // 重新检查摄像头可用性（权限可能刚被授权）
            cameraManager.refreshCameraDevices()
            // 等待一下让权限状态更新
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
            try await cameraManager.startCapture()
        }
        
        switch mode {
        case .fullScreen:
            try await startFullScreenRecording()
        case .selectedArea(let rect):
            try await startAreaRecording(rect: rect)
        }
        
        isRecording = true
        print("✅ 屏幕录制已开始")
    }
    
    func stopRecording() async throws {
        guard isRecording else { return }
        
        print("⏹️  停止屏幕录制...")
        
        // 停止stream
        if let stream = stream {
            try await stream.stopCapture()
        }
        stream = nil
        
        // 停止AVAudioEngine录制 (仅macOS 13-14)
        if #available(macOS 15.0, *) {
            // macOS 15+使用SCK，无需停止AVAudioEngine
        } else {
            avAudioEngineRecorder?.stopRecording()
            avAudioEngineRecorder = nil
        }
        
        // 停止独立摄像头视频轨，再关闭摄像头采集
        await stopCameraTrackRecording()
        cameraManager.stopCapture()
        
        // 完成视频写入
        await finishVideoWriting()
        
        isRecording = false
        frameCount = 0
        audioStartOffset = nil  // 重置音频时间偏移
        firstVideoFrameTime = nil  // 重置首帧视频时间

        print("✅ 屏幕录制已停止")
    }
    
    // MARK: - 全屏录制
    private func startFullScreenRecording() async throws {
        print("📺 开始全屏录制...")
        
        let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = availableContent.displays.first else {
            throw RecordingError.noDisplayFound
        }
        
        isFullScreen = true
        recordingRect = display.frame
        
        try await setupStreamAndWriter(for: display, rect: nil)
    }
    
    // MARK: - 区域录制  
    private func startAreaRecording(rect: CGRect) async throws {
        print("🔍 开始区域录制: \(rect)")
        
        let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = availableContent.displays.first else {
            throw RecordingError.noDisplayFound
        }
        
        isFullScreen = false
        recordingRect = rect
        
        // 保存选择的区域到UserDefaults
        saveSelectedArea(rect)
        
        try await setupStreamAndWriter(for: display, rect: rect)
    }
    
    // MARK: - Stream 和 Writer 设置
    private func setupStreamAndWriter(for display: SCDisplay, rect: CGRect?) async throws {
        guard let outputURL = outputURL else {
            throw RecordingError.invalidOutputURL
        }
        
        // 设置录制配置
        let config = SCStreamConfiguration()
        
        // 视频质量配置
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.scalesToFit = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30fps 更稳定
        
        // 音频配置
        config.capturesAudio = self.systemAudioEnabled
        config.excludesCurrentProcessAudio = true  // 避免录制自己应用的声音
        
        // macOS 15+ 麦克风支持
        if #available(macOS 15.0, *) {
            config.captureMicrophone = self.microphoneEnabled
            if let deviceID = self.microphoneDeviceID {
                config.microphoneCaptureDeviceID = deviceID
            }
        }
        
        if let rect = rect {
            // 🎯 区域录制配置 - 像素对齐优化
            let scaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0
            
            // 1. 像素对齐：确保所有坐标都是整数像素
            let pixelX = round(rect.origin.x * scaleFactor)
            let pixelY = round(rect.origin.y * scaleFactor) 
            let pixelWidth = round(rect.width * scaleFactor)
            let pixelHeight = round(rect.height * scaleFactor)
            
            // 2. 确保宽高为偶数（H.264编码要求）
            let alignedWidth = Int(pixelWidth / 2) * 2
            let alignedHeight = Int(pixelHeight / 2) * 2
            
            // 3. 转换回点坐标（用于sourceRect）
            let alignedRect = CGRect(
                x: pixelX / scaleFactor,
                y: rect.origin.y,  // 暂时保持Y坐标
                width: CGFloat(alignedWidth) / scaleFactor,
                height: CGFloat(alignedHeight) / scaleFactor
            )
            
            // 4. 坐标系转换：macOS（左下） -> ScreenCaptureKit（左上）
            let screenHeight = display.frame.height
            let convertedY = screenHeight - alignedRect.origin.y - alignedRect.height
            let convertedRect = CGRect(
                x: alignedRect.origin.x,
                y: convertedY,
                width: alignedRect.width,
                height: alignedRect.height
            )
            
            // 5. 设置配置：关键是1:1采样，避免缩放
            config.sourceRect = convertedRect
            config.width = alignedWidth
            config.height = alignedHeight
            config.scalesToFit = false  // 关键：禁用缩放
            config.queueDepth = 5
            config.colorSpaceName = CGColorSpace.displayP3
            
            print("🎯 像素对齐优化:")
            print("   原始区域: \(rect)")
            print("   像素对齐后: \(alignedRect)")
            print("   转换后区域: \(convertedRect)")
            print("   输出分辨率: \(alignedWidth)x\(alignedHeight) (1:1采样)")
        } else {
            // 全屏录制配置 - 获取最高分辨率（物理像素）
            if let mainScreen = NSScreen.main {
                let scaleFactor = mainScreen.backingScaleFactor
                let logicalWidth = Int(mainScreen.frame.width)
                let logicalHeight = Int(mainScreen.frame.height)
                
                // 计算物理像素分辨率
                let physicalWidth = Int(Double(logicalWidth) * Double(scaleFactor))
                let physicalHeight = Int(Double(logicalHeight) * Double(scaleFactor))
                
                print("📺 显示器信息:")
                print("   逻辑分辨率: \(logicalWidth)x\(logicalHeight)")
                print("   缩放因子: \(scaleFactor)")
                print("   ScreenCaptureKit报告: \(display.width)x\(display.height)")
                print("   计算物理分辨率: \(physicalWidth)x\(physicalHeight)")
                
                // 使用计算出的物理像素分辨率
                config.width = physicalWidth
                config.height = physicalHeight
                
                // 设置高质量捕获参数
                config.queueDepth = 5
                config.colorSpaceName = CGColorSpace.displayP3
                
                print("📺 最终录制分辨率: \(physicalWidth)x\(physicalHeight)")
            } else {
                // 备用方案：使用 ScreenCaptureKit 报告的分辨率
                config.width = display.width
                config.height = display.height
                print("📺 录制分辨率（备用）: \(display.width)x\(display.height)")
            }
        }
        
        // 设置录制内容过滤器
        let filter = SCContentFilter(display: display, excludingWindows: [])
        
        // 创建并配置stream
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        
        // 设置视频写入器
        try setupVideoWriter(width: config.width, height: config.height, outputURL: outputURL)
        
        // 设置音频录制
        if self.systemAudioEnabled || self.microphoneEnabled {
            try setupAudioCapture(
                systemAudioEnabled: self.systemAudioEnabled, 
                microphoneEnabled: self.microphoneEnabled,
                microphoneDeviceID: self.microphoneDeviceID
            )
        }
        
        // 在添加所有输入后，开始写入会话
        guard let writer = videoWriter else {
            throw RecordingError.writerNotFound
        }
        guard writer.startWriting() else {
            throw RecordingError.writerSetupFailed
        }
        print("✅ AVAssetWriter 开始写入")
        
        // 添加视频输出回调
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "videoQueue"))
        
        // 开始捕获
        try await stream?.startCapture()

        if enableCameraOverlay {
            startCameraTrackRecording()
        }
        
        // 启动AVAudioEngine麦克风录制 (仅macOS 13-14)
        if #available(macOS 15.0, *) {
            // macOS 15+使用SCK，无需额外启动AVAudioEngine
        } else {
            if let avRecorder = avAudioEngineRecorder,
               let micInput = microphoneWriterInput {
                try avRecorder.startRecording(writerInput: micInput)
                print("🎤 AVAudioEngine开始录制麦克风")
            }
        }
        
        print("📹 Stream配置完成 - 分辨率: \(config.width)x\(config.height)")
    }
    
    // MARK: - 音频录制设置
    private func setupAudioCapture(
        systemAudioEnabled: Bool,
        microphoneEnabled: Bool,
        microphoneDeviceID: String?
    ) throws {
        print("🎤 设置音频录制 - 系统音频: \(systemAudioEnabled), 麦克风: \(microphoneEnabled)")
        
        guard let videoWriter = videoWriter else {
            throw RecordingError.writerNotFound
        }
        
        // 设置系统音频录制
        if systemAudioEnabled {
            try setupSystemAudioInput(videoWriter: videoWriter)
            try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audioQueue"))
            print("✅ 系统音频录制已启用")
        }
        
        // 设置麦克风录制
        if microphoneEnabled {
            if #available(macOS 15.0, *) {
                // macOS 15+: 使用ScreenCaptureKit原生支持
                try setupMicrophoneInput(videoWriter: videoWriter)
                try stream?.addStreamOutput(self, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "microphoneQueue"))
                print("✅ 麦克风录制已启用 (SCK原生支持)")
            } else {
                // macOS 13-14: 使用AVAudioEngine
                try setupAVAudioEngineMicrophone(
                    videoWriter: videoWriter,
                    deviceID: microphoneDeviceID
                )
                print("✅ 麦克风录制已启用 (AVAudioEngine兼容方案)")
            }
        }
    }
    
    private func setupSystemAudioInput(videoWriter: AVAssetWriter) throws {
        // 配置系统音频输入
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]
        
        audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioWriterInput?.expectsMediaDataInRealTime = true
        
        guard let audioInput = audioWriterInput else {
            throw RecordingError.audioSetupFailed
        }
        
        guard videoWriter.canAdd(audioInput) else {
            throw RecordingError.audioSetupFailed
        }
        
        videoWriter.add(audioInput)
        print("🔊 系统音频输入已配置")
    }
    
    // MARK: - AVAudioEngine麦克风设置
    private func setupAVAudioEngineMicrophone(videoWriter: AVAssetWriter, deviceID: String?) throws {
        // 配置麦克风音频输入
        let micSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,  // 立体声
            AVEncoderBitRateKey: 128000
        ]
        
        microphoneWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
        microphoneWriterInput?.expectsMediaDataInRealTime = true
        
        guard let micInput = microphoneWriterInput else {
            throw RecordingError.audioSetupFailed
        }
        
        guard videoWriter.canAdd(micInput) else {
            throw RecordingError.audioSetupFailed
        }
        
        videoWriter.add(micInput)
        
        // 创建并配置AVAudioEngine录制器
        avAudioEngineRecorder = AVAudioEngineRecorder()
        
        // 设置音频设备
        if let deviceID = deviceID,
           let audioDeviceID = AudioDeviceID(deviceID) {
            avAudioEngineRecorder?.setInputDevice(deviceID: audioDeviceID)
        }
        
        print("🎤 AVAudioEngine麦克风录制已配置")
    }
    
    @available(macOS 15.0, *)
    private func setupMicrophoneInput(videoWriter: AVAssetWriter) throws {
        // 配置麦克风音频输入（独立轨道）
        let micSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,  // 麦克风通常是单声道
            AVEncoderBitRateKey: 64000
        ]
        
        microphoneWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
        microphoneWriterInput?.expectsMediaDataInRealTime = true
        
        guard let micInput = microphoneWriterInput else {
            throw RecordingError.audioSetupFailed
        }
        
        guard videoWriter.canAdd(micInput) else {
            throw RecordingError.audioSetupFailed
        }
        
        videoWriter.add(micInput)
        print("🎤 SCK麦克风输入已配置")
    }
    
    // MARK: - 视频写入器设置
    private func setupVideoWriter(width: Int, height: Int, outputURL: URL) throws {
        // 删除已存在的文件
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        // 创建视频写入器（使用 .mov 以便后续混音和兼容性更好）
        videoWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        
        guard let writer = videoWriter else {
            throw RecordingError.writerSetupFailed
        }
        
        // 视频输入配置 - 优化后的高质量设置
        let totalPixels = width * height
        let bitsPerPixel: Double
        
        // 🎯 关键优化：区域录制使用更高的单位像素码率
        // 因为区域录制通常包含更多细节内容（如代码、文字）
        if !isFullScreen {
            // 区域录制：提高单位像素码率
            if totalPixels > 1920 * 1080 {
                bitsPerPixel = 0.15  // 更高质量
            } else if totalPixels > 1280 * 720 {
                bitsPerPixel = 0.18
            } else {
                bitsPerPixel = 0.20  // 小区域使用最高质量
            }
        } else {
            // 全屏录制：标准码率
            if totalPixels > 1920 * 1080 {
                bitsPerPixel = 0.10
            } else if totalPixels > 1280 * 720 {
                bitsPerPixel = 0.12
            } else {
                bitsPerPixel = 0.15
            }
        }
        
        let bitRate = Int(Double(totalPixels) * bitsPerPixel * 30.0)  // 30fps
        
        print("🎥 编码优化设置:")
        print("   分辨率: \(width)x\(height)")
        print("   像素总数: \(totalPixels)")
        print("   单位像素码率: \(bitsPerPixel) bits/pixel/frame")
        print("   总码率: \(bitRate) bps (\(bitRate/1000000) Mbps)")
        print("   模式: \(isFullScreen ? "全屏" : "区域")")
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoMaxKeyFrameIntervalKey: 15,  // 区域录制更频繁的关键帧
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                // 额外的质量参数
                AVVideoQualityKey: isFullScreen ? 0.85 : 0.95  // 区域录制使用更高质量
            ]
        ]
        
        videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput?.expectsMediaDataInRealTime = true
        
        guard let writerInput = videoWriterInput else {
            throw RecordingError.writerSetupFailed
        }
        
        // 像素缓冲适配器
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        
        pixelBufferAdapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        
        writer.add(writerInput)
        
        // 注意：不在这里调用 startWriting()，需要先添加音频输入
        
        recordingStartTime = CMTime.zero
        
        print("🎥 视频写入器配置完成")
    }

    // MARK: - 独立摄像头视频轨
    private func startCameraTrackRecording() {
        guard cameraRecordingTask == nil, let outputURL else { return }

        cameraOutputURL = siblingOutputURL(for: outputURL, suffix: "camera", extension: "mov")
        overlayMetadataURL = siblingOutputURL(for: outputURL, suffix: "overlay", extension: "json")
        cameraFrameCount = 0
        cameraFirstFrameDate = nil
        cameraOutputDimensions = nil
        overlayMetadataStartDate = nil
        overlayMetadataSamples = []

        if let cameraOutputURL, FileManager.default.fileExists(atPath: cameraOutputURL.path) {
            try? FileManager.default.removeItem(at: cameraOutputURL)
        }
        if let overlayMetadataURL, FileManager.default.fileExists(atPath: overlayMetadataURL.path) {
            try? FileManager.default.removeItem(at: overlayMetadataURL)
        }

        cameraRecordingTask = Task { @MainActor [weak self] in
            await self?.recordCameraFrames()
        }

        print("📷 独立摄像头视频轨开始: \(cameraOutputURL?.lastPathComponent ?? "")")
    }

    private func recordCameraFrames() async {
        while !Task.isCancelled {
            if let pixelBuffer = cameraManager.getCurrentFrame() {
                appendCameraFrame(pixelBuffer)
            }

            try? await Task.sleep(nanoseconds: 33_333_333)
        }
    }

    private func appendCameraFrame(_ pixelBuffer: CVPixelBuffer) {
        let processedFrame = CameraFrameProcessor.mirroredVisibleImage(from: pixelBuffer)

        do {
            if cameraWriter == nil {
                let dimensions = CameraFrameProcessor.evenDimensions(for: processedFrame.extent.size)
                try setupCameraVideoWriter(width: dimensions.width, height: dimensions.height)
            }
        } catch {
            print("❌ 摄像头视频写入器创建失败: \(error.localizedDescription)")
            cameraRecordingTask?.cancel()
            return
        }

        guard let writer = cameraWriter,
              let writerInput = cameraWriterInput,
              let adapter = cameraPixelBufferAdapter,
              let dimensions = cameraOutputDimensions,
              writer.status == .writing else {
            return
        }

        let currentFrameDate = Date()
        if cameraFirstFrameDate == nil {
            cameraFirstFrameDate = currentFrameDate
            overlayMetadataStartDate = currentFrameDate
            writer.startSession(atSourceTime: .zero)
        }

        guard let firstFrameDate = cameraFirstFrameDate else { return }

        if cameraFrameCount % 8 == 0 {
            captureOverlayMetadataSample()
        }

        guard writerInput.isReadyForMoreMediaData,
              let outputPixelBuffer = renderCameraFrame(
                processedFrame.image,
                sourceExtent: processedFrame.extent,
                width: dimensions.width,
                height: dimensions.height,
                adapter: adapter
              ) else {
            return
        }

        let presentationTime = CMTime(
            seconds: currentFrameDate.timeIntervalSince(firstFrameDate),
            preferredTimescale: 600
        )

        if adapter.append(outputPixelBuffer, withPresentationTime: presentationTime) {
            cameraFrameCount += 1
        } else {
            print("⚠️  摄像头帧写入失败: \(cameraFrameCount)")
        }
    }

    private func setupCameraVideoWriter(width: Int, height: Int) throws {
        guard let cameraOutputURL else { return }

        cameraWriter = try AVAssetWriter(outputURL: cameraOutputURL, fileType: .mov)
        guard let writer = cameraWriter else {
            throw RecordingError.writerSetupFailed
        }

        let bitRate = max(4_000_000, width * height * 4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoQualityKey: 0.9
            ]
        ]

        cameraWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        cameraWriterInput?.expectsMediaDataInRealTime = true

        guard let writerInput = cameraWriterInput, writer.canAdd(writerInput) else {
            throw RecordingError.writerSetupFailed
        }

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        cameraPixelBufferAdapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw RecordingError.writerSetupFailed
        }

        cameraOutputDimensions = (width, height)
        print("📷 摄像头视频写入器配置完成: \(width)x\(height)")
    }

    private func renderCameraFrame(
        _ image: CIImage,
        sourceExtent: CGRect,
        width: Int,
        height: Int,
        adapter: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        guard let pixelBufferPool = adapter.pixelBufferPool else { return nil }

        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let outputPixelBuffer else {
            return nil
        }

        let outputExtent = CGRect(x: 0, y: 0, width: width, height: height)
        let scale = CGAffineTransform(
            scaleX: CGFloat(width) / max(sourceExtent.width, 1),
            y: CGFloat(height) / max(sourceExtent.height, 1)
        )
        let scaledImage = image.transformed(by: scale)

        cameraCIContext.render(
            scaledImage,
            to: outputPixelBuffer,
            bounds: outputExtent,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return outputPixelBuffer
    }

    private func stopCameraTrackRecording() async {
        let task = cameraRecordingTask
        cameraRecordingTask = nil
        task?.cancel()
        await task?.value

        captureOverlayMetadataSample()

        if let writer = cameraWriter {
            cameraWriterInput?.markAsFinished()
            await writer.finishWriting()

            switch writer.status {
            case .completed:
                print("✅ 摄像头视频保存成功: \(cameraOutputURL?.lastPathComponent ?? "")")
            case .failed:
                print("❌ 摄像头视频保存失败: \(writer.error?.localizedDescription ?? "未知错误")")
            case .cancelled:
                print("⚠️  摄像头视频写入被取消")
            default:
                print("⚠️  摄像头视频写入状态未知: \(writer.status.rawValue)")
            }
        }

        writeOverlayMetadataFile()

        cameraWriter = nil
        cameraWriterInput = nil
        cameraPixelBufferAdapter = nil
        cameraOutputDimensions = nil
        cameraFirstFrameDate = nil
        overlayMetadataStartDate = nil
        overlayMetadataSamples = []
    }

    private func captureOverlayMetadataSample() {
        guard enableCameraOverlay,
              let startDate = overlayMetadataStartDate,
              let snapshot = cameraOverlaySnapshotProvider?() else {
            return
        }

        let elapsedTime = Date().timeIntervalSince(startDate)
        let sample = CameraOverlayMetadataSample(
            time: elapsedTime,
            frame: CodableRect(snapshot.frame),
            shape: metadataValue(for: snapshot.shape),
            size: metadataValue(for: snapshot.size)
        )

        if let lastSample = overlayMetadataSamples.last,
           abs(lastSample.time - sample.time) < 0.2,
           lastSample.frame == sample.frame,
           lastSample.shape == sample.shape,
           lastSample.size == sample.size {
            return
        }

        overlayMetadataSamples.append(sample)
    }

    private func writeOverlayMetadataFile() {
        guard let overlayMetadataURL, let outputURL else { return }

        let metadata = CameraOverlayMetadataFile(
            version: 1,
            screenFile: outputURL.lastPathComponent,
            cameraFile: cameraOutputURL?.lastPathComponent,
            coordinateSpace: "macOS global screen points; origin is bottom-left",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            recordingMode: isFullScreen ? "fullScreen" : "selectedArea",
            recordingRect: recordingRect.map(CodableRect.init),
            samples: overlayMetadataSamples
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: overlayMetadataURL)
            print("✅ 摄像头叠加元数据保存成功: \(overlayMetadataURL.lastPathComponent)")
        } catch {
            print("❌ 摄像头叠加元数据保存失败: \(error.localizedDescription)")
        }
    }

    private func siblingOutputURL(for outputURL: URL, suffix: String, extension pathExtension: String) -> URL {
        let baseName = outputURL.deletingPathExtension().lastPathComponent
        return outputURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseName)_\(suffix)")
            .appendingPathExtension(pathExtension)
    }

    private func metadataValue(for shape: CameraOverlayShape) -> String {
        switch shape {
        case .circle:
            return "circle"
        case .roundedSquare:
            return "roundedRectangle"
        }
    }

    private func metadataValue(for size: CameraOverlaySize) -> String {
        switch size {
        case .small:
            return "small"
        case .medium:
            return "medium"
        case .large:
            return "large"
        }
    }

    // MARK: - 自动合成视频
    private func exportCompositedVideoIfNeeded(for screenURL: URL) async {
        guard enableCameraOverlay,
              let cameraURL = cameraOutputURL,
              let overlayMetadataURL,
              FileManager.default.fileExists(atPath: cameraURL.path),
              FileManager.default.fileExists(atPath: overlayMetadataURL.path) else {
            return
        }

        let compositedURL = siblingOutputURL(for: screenURL, suffix: "composited", extension: "mov")
        let tempVideoURL = siblingOutputURL(for: screenURL, suffix: "composited_video_tmp", extension: "mov")

        do {
            let metadataData = try Data(contentsOf: overlayMetadataURL)
            let metadata = try JSONDecoder().decode(CameraOverlayMetadataFile.self, from: metadataData)

            try? FileManager.default.removeItem(at: compositedURL)
            try? FileManager.default.removeItem(at: tempVideoURL)

            print("🎞️  开始合成视频: \(compositedURL.lastPathComponent)")
            let rendered = try renderCompositedVideo(
                screenURL: screenURL,
                cameraURL: cameraURL,
                metadata: metadata,
                outputURL: tempVideoURL
            )

            guard rendered else {
                print("❌ 合成视频渲染失败")
                return
            }

            let muxed = await muxAudioFromScreenVideo(
                screenURL: screenURL,
                videoOnlyURL: tempVideoURL,
                outputURL: compositedURL
            )

            if muxed {
                try? FileManager.default.removeItem(at: tempVideoURL)
                print("✅ 合成视频保存成功: \(compositedURL.lastPathComponent)")
            } else {
                try FileManager.default.moveItem(at: tempVideoURL, to: compositedURL)
                print("✅ 合成视频保存成功（无音频复用）: \(compositedURL.lastPathComponent)")
            }
        } catch {
            print("❌ 合成视频失败: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempVideoURL)
        }
    }

    private func renderCompositedVideo(
        screenURL: URL,
        cameraURL: URL,
        metadata: CameraOverlayMetadataFile,
        outputURL: URL
    ) throws -> Bool {
        let screenAsset = AVURLAsset(url: screenURL)
        let cameraAsset = AVURLAsset(url: cameraURL)

        guard let screenTrack = screenAsset.tracks(withMediaType: .video).first,
              let cameraTrack = cameraAsset.tracks(withMediaType: .video).first else {
            return false
        }

        let screenSize = normalizedVideoSize(for: screenTrack)
        let outputWidth = max(2, Int(screenSize.width.rounded(.down)) / 2 * 2)
        let outputHeight = max(2, Int(screenSize.height.rounded(.down)) / 2 * 2)

        let screenReader = try AVAssetReader(asset: screenAsset)
        let cameraReader = try AVAssetReader(asset: cameraAsset)

        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let screenOutput = AVAssetReaderTrackOutput(track: screenTrack, outputSettings: readerSettings)
        screenOutput.alwaysCopiesSampleData = false
        guard screenReader.canAdd(screenOutput) else { return false }
        screenReader.add(screenOutput)

        let cameraOutput = AVAssetReaderTrackOutput(track: cameraTrack, outputSettings: readerSettings)
        cameraOutput.alwaysCopiesSampleData = false
        guard cameraReader.canAdd(cameraOutput) else { return false }
        cameraReader.add(cameraOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(8_000_000, outputWidth * outputHeight * 3),
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoQualityKey: 0.92
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let adapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(writerInput) else { return false }
        writer.add(writerInput)

        guard screenReader.startReading(),
              cameraReader.startReading(),
              writer.startWriting() else {
            return false
        }

        writer.startSession(atSourceTime: .zero)

        var currentCameraPixelBuffer: CVPixelBuffer?
        var currentCameraTime = CMTime.zero
        var nextCameraSample = cameraOutput.copyNextSampleBuffer()
        var maskCache: [String: CIImage] = [:]
        let outputExtent = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)

        func advanceCameraFrame(to screenTime: CMTime) {
            while let sample = nextCameraSample {
                let sampleTime = CMSampleBufferGetPresentationTimeStamp(sample)
                guard sampleTime <= screenTime || currentCameraPixelBuffer == nil else {
                    break
                }

                if let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                    currentCameraPixelBuffer = pixelBuffer
                    currentCameraTime = sampleTime
                }

                nextCameraSample = cameraOutput.copyNextSampleBuffer()
            }
        }

        while let screenSample = screenOutput.copyNextSampleBuffer() {
            let screenTime = CMSampleBufferGetPresentationTimeStamp(screenSample)
            advanceCameraFrame(to: screenTime)

            guard let screenPixelBuffer = CMSampleBufferGetImageBuffer(screenSample),
                  let outputPixelBuffer = createPixelBuffer(from: adapter) else {
                continue
            }

            let screenImage = CIImage(cvPixelBuffer: screenPixelBuffer)
            let cameraImage = currentCameraPixelBuffer.map { CIImage(cvPixelBuffer: $0) }
            let seconds = max(0, CMTimeGetSeconds(screenTime))
            let sample = overlaySample(at: seconds, in: metadata.samples)
            let composedImage = composeScreenImage(
                screenImage,
                cameraImage: cameraImage,
                overlaySample: sample,
                metadata: metadata,
                outputExtent: outputExtent,
                maskCache: &maskCache
            )

            cameraCIContext.render(
                composedImage,
                to: outputPixelBuffer,
                bounds: outputExtent,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )

            while !writerInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }

            let presentationTime = screenTime.isValid ? screenTime : currentCameraTime
            adapter.append(outputPixelBuffer, withPresentationTime: presentationTime)
        }

        writerInput.markAsFinished()
        screenReader.cancelReading()
        cameraReader.cancelReading()

        let completed = DispatchSemaphore(value: 0)
        writer.finishWriting {
            completed.signal()
        }
        completed.wait()

        return writer.status == .completed
    }

    private func composeScreenImage(
        _ screenImage: CIImage,
        cameraImage: CIImage?,
        overlaySample: CameraOverlayMetadataSample?,
        metadata: CameraOverlayMetadataFile,
        outputExtent: CGRect,
        maskCache: inout [String: CIImage]
    ) -> CIImage {
        guard let cameraImage, let overlaySample else {
            return screenImage.cropped(to: outputExtent)
        }

        let targetRect = overlayTargetRect(
            from: overlaySample.frame.cgRect,
            metadata: metadata,
            outputExtent: outputExtent
        )

        guard targetRect.width > 1, targetRect.height > 1 else {
            return screenImage.cropped(to: outputExtent)
        }

        let scaledCamera = aspectFill(
            cameraImage,
            sourceExtent: cameraImage.extent,
            targetRect: targetRect
        )

        let mask = overlayMask(
            size: targetRect.size,
            shape: overlaySample.shape,
            cache: &maskCache
        ).transformed(by: CGAffineTransform(translationX: targetRect.minX, y: targetRect.minY))

        let blendedImage = scaledCamera.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: screenImage.cropped(to: outputExtent),
            kCIInputMaskImageKey: mask
        ])

        return blendedImage.cropped(to: outputExtent)
    }

    private func aspectFill(
        _ image: CIImage,
        sourceExtent: CGRect,
        targetRect: CGRect
    ) -> CIImage {
        let scale = max(
            targetRect.width / max(sourceExtent.width, 1),
            targetRect.height / max(sourceExtent.height, 1)
        )
        let scaledWidth = sourceExtent.width * scale
        let scaledHeight = sourceExtent.height * scale
        let translationX = targetRect.midX - scaledWidth / 2 - sourceExtent.minX * scale
        let translationY = targetRect.midY - scaledHeight / 2 - sourceExtent.minY * scale

        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: translationX, y: translationY))
    }

    private func overlayTargetRect(
        from overlayFrame: CGRect,
        metadata: CameraOverlayMetadataFile,
        outputExtent: CGRect
    ) -> CGRect {
        let sourceRect = metadata.recordingRect?.cgRect ?? outputExtent
        let scaleX = outputExtent.width / max(sourceRect.width, 1)
        let scaleY = outputExtent.height / max(sourceRect.height, 1)

        return CGRect(
            x: (overlayFrame.minX - sourceRect.minX) * scaleX,
            y: (overlayFrame.minY - sourceRect.minY) * scaleY,
            width: overlayFrame.width * scaleX,
            height: overlayFrame.height * scaleY
        )
    }

    private func overlayMask(size: CGSize, shape: String, cache: inout [String: CIImage]) -> CIImage {
        let width = max(2, Int(size.width.rounded()))
        let height = max(2, Int(size.height.rounded()))
        let key = "\(shape)-\(width)x\(height)"

        if let cachedMask = cache[key] {
            return cachedMask
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))

        if shape == "circle" {
            context.fillEllipse(in: rect)
        } else {
            let radius = max(24, min(CGFloat(width), CGFloat(height)) * 0.16)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }

        guard let cgImage = context.makeImage() else {
            return CIImage(color: .white).cropped(to: rect)
        }

        let mask = CIImage(cgImage: cgImage)
        cache[key] = mask
        return mask
    }

    private func overlaySample(
        at seconds: Double,
        in samples: [CameraOverlayMetadataSample]
    ) -> CameraOverlayMetadataSample? {
        guard var selectedSample = samples.first else { return nil }

        for sample in samples {
            guard sample.time <= seconds else { break }
            selectedSample = sample
        }

        return selectedSample
    }

    private func createPixelBuffer(from adapter: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pixelBufferPool = adapter.pixelBufferPool else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private func normalizedVideoSize(for track: AVAssetTrack) -> CGSize {
        let naturalSize = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height))
    }

    private func muxAudioFromScreenVideo(
        screenURL: URL,
        videoOnlyURL: URL,
        outputURL: URL
    ) async -> Bool {
        let screenAsset = AVURLAsset(url: screenURL)
        let videoAsset = AVURLAsset(url: videoOnlyURL)
        let audioTracks = screenAsset.tracks(withMediaType: .audio)

        guard !audioTracks.isEmpty,
              let videoTrack = videoAsset.tracks(withMediaType: .video).first else {
            return false
        }

        let composition = AVMutableComposition()

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return false
        }

        do {
            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoAsset.duration),
                of: videoTrack,
                at: .zero
            )

            for audioTrack in audioTracks {
                guard let compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }

                try compositionAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: videoAsset.duration),
                    of: audioTrack,
                    at: .zero
                )
            }
        } catch {
            print("❌ 合成视频复用音频失败: \(error.localizedDescription)")
            return false
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            return false
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            exporter.exportAsynchronously {
                continuation.resume(returning: exporter.status == .completed)
            }
        }
    }
    
    // MARK: - 完成视频写入
    private func finishVideoWriting() async {
        guard let writer = videoWriter else { return }
        
        print("🎬 完成视频写入，总帧数: \(frameCount)")
        
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        microphoneWriterInput?.markAsFinished()
        
        await writer.finishWriting()
        
        switch writer.status {
        case .completed:
            print("✅ 视频文件保存成功: \(outputURL?.lastPathComponent ?? "")")
            if let url = outputURL {
                let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
                print("📄 文件大小: \(fileSize ?? 0) bytes")
            }

            // 录制完成后对音频进行双声道混音处理（系统音频1/2通道 + 麦克风3通道 -> 2通道）
            if let url = outputURL {
                await mixDownAudioToStereoIfNeeded(for: url)
                await exportCompositedVideoIfNeeded(for: url)
            }
        case .failed:
            print("❌ 视频文件保存失败: \(writer.error?.localizedDescription ?? "未知错误")")
        case .cancelled:
            print("⚠️  视频写入被取消")
        default:
            print("⚠️  视频写入状态未知: \(writer.status.rawValue)")
        }
        
        // 清理资源
        videoWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        microphoneWriterInput = nil
        pixelBufferAdapter = nil
    }

    // MARK: - 录制后音频混音（下混为双声道）
    private func mixDownAudioToStereoIfNeeded(for inputURL: URL) async {
        let asset = AVURLAsset(url: inputURL)
        let audioTracks = asset.tracks(withMediaType: .audio)

        // 若没有音频或只有一个音轨则无需混音
        guard audioTracks.count >= 2 else {
            print("ℹ️  音频轨道少于2条，无需混音")
            return
        }

        // 构建合成：保留原视频，叠加所有音频轨道并使用 AVAudioMix 进行混音
        let composition = AVMutableComposition()
        // 视频轨道（尽量原样拷贝，避免重编码）
        if let videoTrack = asset.tracks(withMediaType: .video).first {
            let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            do {
                try compVideo?.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration),
                                               of: videoTrack,
                                               at: .zero)
            } catch {
                print("⚠️  插入视频轨道失败: \(error)")
            }
        }

        // 音频轨道：全部添加到合成，并在导出时通过 AudioMix 同步混合
        var mixParams: [AVAudioMixInputParameters] = []
        for track in audioTracks {
            let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            do {
                try compAudio?.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration),
                                               of: track,
                                               at: .zero)
                let params = AVMutableAudioMixInputParameters(track: compAudio)
                // 默认音量 1.0；如需调整麦克风电平可在此区分 source track 设置不同 volume
                params.setVolume(1.0, at: .zero)
                mixParams.append(params)
            } catch {
                print("⚠️  插入音频轨道失败: \(error)")
            }
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParams

        // 导出到临时文件，再覆盖源文件
        let tempURL = inputURL.deletingPathExtension().appendingPathExtension("mixed.mov")
        // 删除已有的临时文件
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            print("❌ 创建导出会话失败，无法进行混音")
            return
        }
        exporter.outputURL = tempURL
        exporter.outputFileType = .mov
        exporter.audioMix = audioMix
        exporter.shouldOptimizeForNetworkUse = false

        print("🎛️  开始导出混音文件...")
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            exporter.exportAsynchronously {
                continuation.resume(returning: exporter.status == .completed)
            }
        }

        if status {
            print("✅ 混音导出完成: \(tempURL.lastPathComponent)")
            do {
                // 用混音后的文件覆盖原文件
                // 先移除原文件（避免 replaceItemAt 权限问题）
                if FileManager.default.fileExists(atPath: inputURL.path) {
                    try FileManager.default.removeItem(at: inputURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: inputURL)
                print("✅ 已替换为混音后双声道音频的文件")
            } catch {
                print("❌ 替换混音文件失败: \(error)")
            }
        } else {
            print("❌ 混音导出失败: \(exporter.error?.localizedDescription ?? "未知错误")")
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
    
    // MARK: - 区域保存和恢复
    private func saveSelectedArea(_ rect: CGRect) {
        let rectDict: [String: Double] = [
            "x": rect.origin.x,
            "y": rect.origin.y,
            "width": rect.width,
            "height": rect.height
        ]
        UserDefaults.standard.set(rectDict, forKey: "lastSelectedArea")
        print("💾 保存选择区域: \(rect)")
    }
    
    func getLastSelectedArea() -> CGRect? {
        guard let rectDict = UserDefaults.standard.dictionary(forKey: "lastSelectedArea") as? [String: Double],
              let x = rectDict["x"],
              let y = rectDict["y"],
              let width = rectDict["width"],
              let height = rectDict["height"] else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - SCStreamOutput
extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        Task { @MainActor in
            switch type {
            case .screen:
                await processVideoSampleBuffer(sampleBuffer)
            case .audio:
                await processAudioSampleBuffer(sampleBuffer, type: .systemAudio)
            case .microphone:
                if #available(macOS 15.0, *) {
                    await processAudioSampleBuffer(sampleBuffer, type: .microphone)
                }
            @unknown default:
                break
            }
        }
    }
}

// MARK: - SCStreamDelegate
extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("❌ Stream意外停止: \(error.localizedDescription)")
        Task { @MainActor in
            isRecording = false
        }
    }
}

// MARK: - 媒体处理
extension ScreenRecorder {
    // 音频类型枚举
    private enum AudioType {
        case systemAudio
        case microphone
    }
    
    private func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        guard let writer = videoWriter,
              let writerInput = videoWriterInput,
              let adapter = pixelBufferAdapter,
              writer.status == .writing else {
            return
        }

        // 获取图像缓冲
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // 获取当前帧的原始时间戳
        let currentFrameTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // 设置录制开始时间（只设置一次）
        if firstVideoFrameTime == nil {
            firstVideoFrameTime = currentFrameTime
            recordingStartTime = .zero
            writer.startSession(atSourceTime: recordingStartTime)
            print("🎬 录制会话开始，首帧时间: \(CMTimeGetSeconds(currentFrameTime))秒")
        }

        // 计算相对于第一帧的时间差，使用实际时间戳
        guard let firstTime = firstVideoFrameTime else { return }
        let relativeTime = CMTimeSubtract(currentFrameTime, firstTime)

        // 调试输出
        if frameCount % 30 == 0 { // 每秒打印一次
            let seconds = CMTimeGetSeconds(relativeTime)
            print("🎬 视频帧 \(frameCount): \(String(format: "%.3f", seconds))秒")
        }

        // 写入帧数据
        if writerInput.isReadyForMoreMediaData {
            let success = adapter.append(pixelBuffer, withPresentationTime: relativeTime)
            if success {
                frameCount += 1
            } else {
                print("⚠️  帧写入失败，帧号: \(frameCount)")
            }
        } else {
            print("⚠️  写入器未就绪，跳过帧: \(frameCount)")
        }
    }
    
    // MARK: - 音频时间戳调整
    private func adjustAudioTimestamp(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        // 获取原始时间戳
        let originalTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        // 如果是第一个音频样本，记录音频开始时间偏移
        if audioStartOffset == nil {
            audioStartOffset = originalTime
            print("🎵 音频开始时间偏移: \(CMTimeGetSeconds(originalTime))秒")
        }
        
        guard let offset = audioStartOffset else { return nil }
        
        // 计算调整后的时间戳（从0开始）
        let adjustedTime = CMTimeSubtract(originalTime, offset)
        
        // 创建新的样本缓冲区
        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: adjustedTime,
            decodeTimeStamp: .invalid
        )
        
        var adjustedBuffer: CMSampleBuffer?
        let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        
        // 获取音频数据
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: dataBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMSampleBufferGetNumSamples(sampleBuffer),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &adjustedBuffer
        )
        
        if status != noErr {
            print("❌ 创建调整后的音频样本缓冲失败: \(status)")
            return nil
        }
        
        return adjustedBuffer
    }
    
    // MARK: - 音频处理
    private func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, type: AudioType) async {
        guard let writer = videoWriter,
              writer.status == .writing else {
            return
        }
        
        let writerInput: AVAssetWriterInput?
        
        switch type {
        case .systemAudio:
            writerInput = audioWriterInput
        case .microphone:
            writerInput = microphoneWriterInput
        }
        
        guard let input = writerInput else {
            print("⚠️  音频写入器不可用: \(type)")
            return
        }
        
        // 调整音频时间戳以匹配视频时间轴
        guard let adjustedBuffer = adjustAudioTimestamp(sampleBuffer) else {
            print("⚠️  无法调整音频时间戳: \(type)")
            return
        }
        
        if input.isReadyForMoreMediaData {
            let success = input.append(adjustedBuffer)
            if success {
                // 音频写入成功
                if frameCount % 300 == 0 {  // 每10秒打印一次
                    print("🔊 音频样本写入成功: \(type)")
                }
            } else {
                print("❌ 音频样本写入失败: \(type)")
            }
        } else {
            print("⚠️  音频写入器未就绪: \(type)")
        }
    }
}

// MARK: - 错误类型
enum RecordingError: Error, LocalizedError {
    case invalidState
    case noDisplayFound
    case invalidOutputURL
    case writerSetupFailed
    case writerNotFound
    case audioSetupFailed
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .invalidState:
            return "录制状态无效"
        case .noDisplayFound:
            return "未找到可录制的显示器"
        case .invalidOutputURL:
            return "输出文件路径无效"
        case .writerSetupFailed:
            return "视频写入器设置失败"
        case .writerNotFound:
            return "视频写入器未找到"
        case .audioSetupFailed:
            return "音频设置失败"
        case .permissionDenied:
            return "屏幕录制权限被拒绝"
        }
    }
}
