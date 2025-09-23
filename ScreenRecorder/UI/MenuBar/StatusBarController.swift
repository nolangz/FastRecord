import Cocoa
import SwiftUI
import Combine

@MainActor
class StatusBarController: ObservableObject {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private var recordingState: RecordingState
    private var recordingTimer: Timer?
    private var areaSelector: AreaSelector
    private var screenRecorder: ScreenRecorder
    private var circularCameraWindow: CircularCameraWindow?
    private var recordingIndicator: RecordingIndicatorWindow?
    private var audioManager: AudioManager
    
    var permissionsManager: PermissionsManager?
    
    init() {
        print("🔧 初始化状态栏控制器...")
        
        statusBar = NSStatusBar()
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        recordingState = RecordingState()
        areaSelector = AreaSelector()
        screenRecorder = ScreenRecorder()
        recordingIndicator = RecordingIndicatorWindow()
        audioManager = AudioManager()
        
        setupStatusItem()
        setupPopover()
        setupRecordingStateObserver()
        
        print("✅ 状态栏控制器初始化完成")
    }
    
    private func setupStatusItem() {
        guard let statusBarButton = statusItem.button else { return }
        
        // 设置状态栏图标
        updateStatusIcon()
        
        // 设置点击事件
        statusBarButton.action = #selector(togglePopover)
        statusBarButton.target = self
        
        print("📱 状态栏按钮设置完成")
    }
    
    private func setupPopover() {
        popover.contentSize = NSSize(width: 300, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                recordingState: recordingState,
                permissionsManager: permissionsManager,
                audioManager: audioManager,
                onStartRecording: { [weak self] in
                    self?.startRecording()
                },
                onStopRecording: { [weak self] in
                    self?.stopRecording()
                },
                onSelectArea: { [weak self] in
                    self?.selectRecordingArea()
                }
            )
        )
        
        print("🎛️  状态栏弹出菜单设置完成")
    }
    
    private func setupRecordingStateObserver() {
        // 监听摄像头叠加开关变化
        recordingState.$cameraOverlayEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.handleCameraOverlayToggle(enabled: enabled)
            }
            .store(in: &cancellables)
            
        // 监听摄像头大小变化
        recordingState.$cameraOverlaySize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                self?.handleCameraSizeChange(size: size)
            }
            .store(in: &cancellables)
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    private func handleCameraOverlayToggle(enabled: Bool) {
        guard recordingState.isRecording else { return }
        
        if enabled {
            // 录制中启用摄像头叠加
            print("📷 录制中启用摄像头叠加")
            
            Task {
                // 检查摄像头权限
                if let permissionsManager = permissionsManager, !permissionsManager.cameraAuthorized {
                    print("📷 摄像头权限未授权，请求权限...")
                    await permissionsManager.requestCameraPermission()
                    
                    if !permissionsManager.cameraAuthorized {
                        print("⚠️  摄像头权限被拒绝，禁用摄像头叠加")
                        await MainActor.run {
                            recordingState.cameraOverlayEnabled = false
                        }
                        return
                    }
                }
                
                await MainActor.run {
                    // 显示摄像头窗口
                    if let cameraManager = screenRecorder.getCameraManager() {
                        if circularCameraWindow == nil {
                            circularCameraWindow = CircularCameraWindow(cameraManager: cameraManager)
                        }
                        
                        let recordingRect: CGRect? = if case .selectedArea(let rect) = recordingState.recordingMode { rect } else { nil }
                        
                        circularCameraWindow?.show(
                            at: recordingState.cameraOverlayPosition,
                            size: recordingState.cameraOverlaySize,
                            recordingRect: recordingRect
                        )
                        
                        // 确保蓝色指示器在前面显示
                        if case .selectedArea(_) = recordingState.recordingMode {
                            recordingIndicator?.bringToFront()
                        }
                    }
                }
            }
        } else {
            // 录制中禁用摄像头叠加
            print("📷 录制中隐藏摄像头叠加")
            circularCameraWindow?.hide()
        }
    }
    
    private func handleCameraSizeChange(size: CameraOverlaySize) {
        guard recordingState.isRecording && recordingState.cameraOverlayEnabled else { return }
        
        print("📏 录制中调整摄像头大小为: \(size)")
        circularCameraWindow?.resizeWindow(to: size)
    }
    
    @objc private func togglePopover() {
        guard let statusBarButton = statusItem.button else { return }
        
        if popover.isShown {
            hidePopover()
        } else {
            showPopover(statusBarButton)
        }
    }
    
    private func showPopover(_ sender: NSStatusBarButton) {
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        print("📋 显示状态栏菜单")
    }

    // 公开方法，用于外部调用显示菜单
    func showMenu() {
        guard let statusBarButton = statusItem.button else { return }
        showPopover(statusBarButton)
    }
    
    private func hidePopover() {
        popover.performClose(nil)
        print("📋 隐藏状态栏菜单")
    }
    
    private func updateStatusIcon() {
        guard let statusBarButton = statusItem.button else { return }
        
        if recordingState.isRecording {
            // 录制中显示红色圆点
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            image?.isTemplate = false
            statusBarButton.image = image
            
            // 设置红色
            statusBarButton.contentTintColor = .systemRed
        } else {
            // 未录制时显示摄像机图标
            let image = NSImage(systemSymbolName: "video", accessibilityDescription: "Screen Recorder")
            image?.isTemplate = true
            statusBarButton.image = image
            statusBarButton.contentTintColor = nil
        }
    }
    
    // MARK: - 录制控制
    private func startRecording() {
        print("🎬 开始录制...")
        
        // 检查权限
        guard let permissionsManager = permissionsManager,
              permissionsManager.essentialPermissionsGranted else {
            print("❌ 缺少必要权限，无法开始录制")
            return
        }
        
        // 检查录制器状态
        guard screenRecorder.canRecord && !screenRecorder.isRecording else {
            print("❌ 录制器不可用或正在录制中")
            return
        }
        
        recordingState.startRecording()
        updateStatusIcon()
        startRecordingTimer()
        hidePopover()
        
        // 启动实际录制
        Task {
            do {
                // 如果启用摄像头叠加且权限未授权，先请求权限
                if recordingState.cameraOverlayEnabled && !permissionsManager.cameraAuthorized {
                    print("📷 摄像头叠加已启用，请求摄像头权限...")
                    await permissionsManager.requestCameraPermission()
                    
                    // 如果权限仍未授权，禁用摄像头叠加
                    if !permissionsManager.cameraAuthorized {
                        print("⚠️  摄像头权限被拒绝，禁用摄像头叠加")
                        await MainActor.run {
                            recordingState.cameraOverlayEnabled = false
                        }
                    }
                }
                
                try await screenRecorder.startRecording(
                    mode: recordingState.recordingMode,
                    outputURL: recordingState.outputURL,
                    cameraOverlay: recordingState.cameraOverlayEnabled,
                    cameraPosition: recordingState.cameraOverlayPosition,
                    cameraSize: recordingState.cameraOverlaySize,
                    systemAudioEnabled: recordingState.systemAudioEnabled,
                    microphoneEnabled: recordingState.microphoneEnabled,
                    microphoneDeviceID: audioManager.getMicrophoneDeviceIDForSCK()
                )
                print("✅ 录制已开始")
                
                // 🎯 显示录制界面元素
                await MainActor.run {
                    // 如果是区域录制，显示蓝色虚线指示器
                    if case .selectedArea(let rect) = recordingState.recordingMode {
                        recordingIndicator?.showIndicator(for: rect)
                    }
                    
                    // 如果启用了摄像头叠加，显示圆形摄像头窗口
                    if recordingState.cameraOverlayEnabled,
                       let cameraManager = screenRecorder.getCameraManager() {
                        if circularCameraWindow == nil {
                            circularCameraWindow = CircularCameraWindow(cameraManager: cameraManager)
                        }
                        
                        let recordingRect: CGRect? = if case .selectedArea(let rect) = recordingState.recordingMode { rect } else { nil }
                        
                        circularCameraWindow?.show(
                            at: recordingState.cameraOverlayPosition,
                            size: recordingState.cameraOverlaySize,
                            recordingRect: recordingRect
                        )
                    }
                }
            } catch {
                print("❌ 录制启动失败: \(error.localizedDescription)")
                await MainActor.run {
                    stopRecording()
                }
            }
        }
    }
    
    private func stopRecording() {
        print("⏹️  停止录制...")
        
        recordingState.stopRecording()
        updateStatusIcon()
        stopRecordingTimer()
        
        // 隐藏录制界面元素
        circularCameraWindow?.hide()
        recordingIndicator?.hideIndicator()
        
        // 停止实际录制
        Task {
            do {
                try await screenRecorder.stopRecording()
                print("✅ 录制已停止")
            } catch {
                print("❌ 录制停止失败: \(error.localizedDescription)")
            }
        }
    }
    
    private func selectRecordingArea() {
        print("🔍 选择录制区域...")
        hidePopover()
        
        areaSelector.selectArea { [weak self] selectedRect in
            guard let self = self, let rect = selectedRect else {
                print("❌ 区域选择被取消")
                return
            }
            
            print("✅ 选择了录制区域: \(rect)")
            self.recordingState.recordingMode = .selectedArea(rect)
            self.recordingState.selectedArea = rect
            
            // 立即开始录制选择的区域
            self.startRecording()
        }
    }
    
    // MARK: - 录制计时器
    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingState.updateRecordingDuration()
            }
        }
    }
    
    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
}

// MARK: - SwiftUI 菜单视图
struct MenuBarView: View {
    @ObservedObject var recordingState: RecordingState
    var permissionsManager: PermissionsManager?
    @ObservedObject var audioManager: AudioManager
    
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    let onSelectArea: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            // 标题
            Text("FastRecord")
                .font(.headline)
                .padding(.top)
            
            // 权限状态
            if let permissions = permissionsManager {
                PermissionsStatusView(permissionsManager: permissions)
            }
            
            // 录制状态
            RecordingStatusView(recordingState: recordingState)
            
            // 录制控制
            RecordingControlsView(
                recordingState: recordingState,
                onStartRecording: onStartRecording,
                onStopRecording: onStopRecording,
                onSelectArea: onSelectArea
            )
            
            // 设置
            SettingsView(recordingState: recordingState, audioManager: audioManager)
            
            Divider()
            
            // 退出按钮
            Button("退出应用") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
            
            Spacer()
        }
        .padding()
        .frame(width: 300, height: 400)
    }
}

// MARK: - 权限状态视图
struct PermissionsStatusView: View {
    @ObservedObject var permissionsManager: PermissionsManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("权限状态")
                .font(.subheadline)
                .fontWeight(.medium)
            
            HStack {
                Image(systemName: permissionsManager.screenRecordingAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(permissionsManager.screenRecordingAuthorized ? .green : .red)
                Text("屏幕录制")
                Spacer()
            }
            
            HStack {
                Image(systemName: permissionsManager.microphoneAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(permissionsManager.microphoneAuthorized ? .green : .orange)
                Text("麦克风")
                Spacer()
            }
            
            HStack {
                Image(systemName: permissionsManager.cameraAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(permissionsManager.cameraAuthorized ? .green : .orange)
                Text("摄像头")
                Spacer()
            }
            
            if !permissionsManager.allPermissionsGranted {
                Button("请求权限") {
                    Task {
                        await permissionsManager.requestAllPermissions()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - 录制状态视图
struct RecordingStatusView: View {
    @ObservedObject var recordingState: RecordingState
    
    var body: some View {
        HStack {
            Circle()
                .fill(recordingState.isRecording ? .red : .gray)
                .frame(width: 12, height: 12)
            
            Text(recordingState.isRecording ? "录制中" : "未录制")
                .font(.subheadline)
            
            if recordingState.isRecording {
                Spacer()
                Text(timeString(from: recordingState.recordingDuration))
                    .font(.subheadline.monospacedDigit())
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private func timeString(from duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - 录制控制视图
struct RecordingControlsView: View {
    @ObservedObject var recordingState: RecordingState
    
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    let onSelectArea: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            // 主要控制按钮
            if recordingState.isRecording {
                Button("停止录制") {
                    onStopRecording()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Button("全屏录制") {
                            recordingState.recordingMode = .fullScreen
                            onStartRecording()
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("选择区域") {
                            onSelectArea()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

// MARK: - 设置视图
struct SettingsView: View {
    @ObservedObject var recordingState: RecordingState
    @ObservedObject var audioManager: AudioManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("设置")
                .font(.subheadline)
                .fontWeight(.medium)
            
            Toggle("麦克风", isOn: $recordingState.microphoneEnabled)
            
            // 麦克风设备选择
            if recordingState.microphoneEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("设备:")
                            .font(.caption)
                        Picker("麦克风设备", selection: $audioManager.selectedMicrophone) {
                            ForEach(audioManager.availableMicrophones) { device in
                                Text(device.name).tag(device)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(audioManager.isLoading)
                        
                        if audioManager.isLoading {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                    }
                    
                    // 显示推荐的音频配置方法
                    let config = audioManager.getRecommendedAudioConfiguration()
                    Text(config.description)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 16)
                .font(.caption)
            }
            
            Toggle("系统音频", isOn: $recordingState.systemAudioEnabled)
            Toggle("摄像头叠加", isOn: $recordingState.cameraOverlayEnabled)
            
            // 摄像头设置
            if recordingState.cameraOverlayEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    // 大小选择
                    HStack {
                        Text("大小:")
                        Picker("大小", selection: $recordingState.cameraOverlaySize) {
                            ForEach(CameraOverlaySize.allCases, id: \.self) { size in
                                Text(size.displayName).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .font(.caption)
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
}