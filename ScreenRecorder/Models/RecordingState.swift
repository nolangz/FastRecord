import Foundation

// MARK: - 导入音频相关模块
// 注意：AudioManager会在后续集成时导入

enum RecordingMode {
    case fullScreen
    case selectedArea(CGRect)
}

enum CameraOverlayPosition: CaseIterable, Hashable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var displayName: String {
        switch self {
        case .topLeft:
            return "左上"
        case .topRight:
            return "右上"
        case .bottomLeft:
            return "左下"
        case .bottomRight:
            return "右下"
        }
    }
}

enum CameraOverlaySize: CaseIterable {
    case small   // 180x180
    case medium  // 280x280
    case large   // 400x400
    
    var size: CGSize {
        switch self {
        case .small:
            return CGSize(width: 180, height: 180)
        case .medium:
            return CGSize(width: 280, height: 280)
        case .large:
            return CGSize(width: 400, height: 400)
        }
    }
    
    var displayName: String {
        switch self {
        case .small:
            return "小"
        case .medium:
            return "中"
        case .large:
            return "大"
        }
    }
}

enum CameraOverlayShape: CaseIterable, Hashable {
    case circle
    case roundedSquare

    var displayName: String {
        switch self {
        case .circle:
            return "圆形"
        case .roundedSquare:
            return "圆角矩形"
        }
    }
}

struct CameraOverlaySnapshot {
    let frame: CGRect
    let shape: CameraOverlayShape
    let size: CameraOverlaySize
}

@MainActor
class RecordingState: ObservableObject {
    @Published var isRecording = false
    @Published var recordingMode: RecordingMode = .fullScreen
    @Published var selectedArea: CGRect = .zero
    
    // 音频设置
    @Published var microphoneEnabled = true
    @Published var systemAudioEnabled = true
    
    // 摄像头叠加层设置
    @Published var cameraOverlayEnabled = true
    @Published var cameraOverlayPosition: CameraOverlayPosition = .topRight
    @Published var cameraOverlaySize: CameraOverlaySize = .medium
    @Published var cameraOverlayShape: CameraOverlayShape = .circle
    
    // 输出设置
    @Published var outputDirectory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
    
    // 录制状态
    @Published var recordingDuration: TimeInterval = 0
    @Published var recordingStartTime: Date?
    
    // 生成输出文件名
    var outputFileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: recordingStartTime ?? Date())

        switch recordingMode {
        case .fullScreen:
            return "ScreenRecord_\(timestamp).mov"
        case .selectedArea(_):
            return "AreaRecord_\(timestamp).mov"
        }
    }
    
    var outputURL: URL {
        return outputDirectory.appendingPathComponent(outputFileName)
    }
    
    func startRecording() {
        isRecording = true
        recordingStartTime = Date()
        recordingDuration = 0
        print("🎬 开始录制: \(outputFileName)")
    }
    
    func stopRecording() {
        isRecording = false
        print("⏹️  停止录制，时长: \(String(format: "%.1f", recordingDuration))秒")
    }
    
    func updateRecordingDuration() {
        guard let startTime = recordingStartTime else { return }
        recordingDuration = Date().timeIntervalSince(startTime)
    }
}
