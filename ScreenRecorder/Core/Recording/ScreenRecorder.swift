import Foundation
import AVFoundation
import ScreenCaptureKit

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
    
    // 录制配置
    private var outputURL: URL?
    private var recordingRect: CGRect?
    private var isFullScreen: Bool = true
    
    // 音频录制配置
    private var systemAudioEnabled: Bool = false
    private var microphoneEnabled: Bool = false
    private var microphoneDeviceID: String? = nil
    
    // 摄像头叠加层
    private var cameraManager: CameraManager?
    private var enableCameraOverlay = false
    private var cameraOverlayPosition: CameraOverlayPosition = .topRight
    private var cameraOverlaySize: CameraOverlaySize = .medium
    
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
        
        if enabled && cameraManager == nil {
            cameraManager = CameraManager()
        }
    }
    
    // MARK: - 获取摄像头管理器
    func getCameraManager() -> CameraManager? {
        return cameraManager
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
            if cameraManager == nil {
                cameraManager = CameraManager()
            }
            // 重新检查摄像头可用性（权限可能刚被授权）
            cameraManager?.checkCameraAvailability()
            // 等待一下让权限状态更新
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
            try await cameraManager?.startCapture()
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
        
        // 停止摄像头
        cameraManager?.stopCapture()
        
        // 完成视频写入
        await finishVideoWriting()
        
        isRecording = false
        frameCount = 0
        audioStartOffset = nil  // 重置音频时间偏移
        
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
        
        // 创建视频写入器
        videoWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
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
        
        // 设置录制开始时间（只设置一次）
        if recordingStartTime == .zero && frameCount == 0 {
            recordingStartTime = .zero  // 从0开始，而不是使用系统时间戳
            writer.startSession(atSourceTime: recordingStartTime)
            print("🎬 录制会话开始，从时间0开始")
        }
        
        // 使用基于帧数的时间戳，确保时长正确
        let frameTime = CMTime(value: frameCount, timescale: 30) // 30fps
        
        // 调试输出
        if frameCount % 30 == 0 { // 每秒打印一次 (30fps)
            let seconds = CMTimeGetSeconds(frameTime)
            print("🎬 录制帧 \(frameCount): \(String(format: "%.2f", seconds))秒")
        }
        
        // 直接使用原始像素缓冲（摄像头会作为屏幕上的窗口被录制）
        
        // 写入帧数据
        if writerInput.isReadyForMoreMediaData {
            let success = adapter.append(pixelBuffer, withPresentationTime: frameTime)
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