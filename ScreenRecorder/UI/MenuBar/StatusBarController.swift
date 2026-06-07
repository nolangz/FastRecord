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
    private var windowSelector: WindowSelector
    private var screenRecorder: ScreenRecorder
    private var circularCameraWindow: CircularCameraWindow?
    private var recordingIndicator: RecordingIndicatorWindow?
    private var audioManager: AudioManager
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var popoverCloseObserver: NSObjectProtocol?
    
    var permissionsManager: PermissionsManager?
    
    init(permissionsManager: PermissionsManager? = nil) {
        print("🔧 初始化状态栏控制器...")
        self.permissionsManager = permissionsManager
        
        // 使用系统级状态栏实例。macOS 26 对菜单栏额外项的进程/应用身份
        // 更严格，NSStatusBar.system 能确保图标注册到当前应用的菜单栏空间。
        statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        recordingState = RecordingState()
        areaSelector = AreaSelector()
        windowSelector = WindowSelector()
        screenRecorder = ScreenRecorder()
        recordingIndicator = RecordingIndicatorWindow()
        audioManager = AudioManager()

        screenRecorder.setCameraOverlaySnapshotProvider { [weak self] in
            self?.circularCameraWindow?.metadataSnapshot()
        }
        
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
        popover.contentSize = NSSize(width: 320, height: 410)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                recordingState: recordingState,
                permissionsManager: permissionsManager,
                audioManager: audioManager,
                cameraManager: screenRecorder.getCameraManager(),
                onStartRecording: { [weak self] in
                    self?.startRecording()
                },
                onStopRecording: { [weak self] in
                    self?.stopRecording()
                },
                onSelectArea: { [weak self] in
                    self?.selectRecordingArea()
                },
                onSelectWindow: { [weak self] in
                    self?.selectRecordingWindow()
                }
            )
        )
        popoverCloseObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopDismissEventMonitoring()
            }
        }
        
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

        recordingState.$cameraOverlayShape
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shape in
                self?.handleCameraShapeChange(shape: shape)
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
                    let cameraManager = screenRecorder.getCameraManager()
                    if circularCameraWindow == nil {
                        circularCameraWindow = CircularCameraWindow(cameraManager: cameraManager)
                    }

                    let recordingRect = currentRecordingFrame()

                    circularCameraWindow?.show(
                        at: recordingState.cameraOverlayPosition,
                        size: recordingState.cameraOverlaySize,
                        shape: recordingState.cameraOverlayShape,
                        recordingRect: recordingRect
                    )

                    // 确保蓝色指示器在前面显示
                    if case .selectedArea(_) = recordingState.recordingMode {
                        recordingIndicator?.bringToFront()
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

    private func handleCameraShapeChange(shape: CameraOverlayShape) {
        guard recordingState.isRecording && recordingState.cameraOverlayEnabled else { return }

        print("⬚ 录制中调整摄像头形状为: \(shape.displayName)")
        circularCameraWindow?.updateShape(to: shape)
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
        Task {
            await permissionsManager?.checkAllPermissions()
        }
        screenRecorder.getCameraManager().refreshCameraDevices()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        startDismissEventMonitoring()
        print("📋 显示状态栏菜单")
    }

    // 公开方法，用于外部调用显示菜单
    func showMenu() {
        guard let statusBarButton = statusItem.button else { return }
        showPopover(statusBarButton)
    }
    
    private func hidePopover() {
        popover.performClose(nil)
        stopDismissEventMonitoring()
        print("📋 隐藏状态栏菜单")
    }

    private func startDismissEventMonitoring() {
        stopDismissEventMonitoring()

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                self?.hidePopoverIfClickIsOutside(event: event)
            }
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hidePopover()
            }
        }
    }

    private func stopDismissEventMonitoring() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }

        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func hidePopoverIfClickIsOutside(event: NSEvent) {
        guard popover.isShown else {
            stopDismissEventMonitoring()
            return
        }

        let screenPoint: NSPoint
        if let eventWindow = event.window {
            screenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
        } else {
            screenPoint = event.locationInWindow
        }

        if popover.contentViewController?.view.window?.frame.contains(screenPoint) == true {
            return
        }

        if statusItem.button?.window?.frame.contains(screenPoint) == true {
            return
        }

        hidePopover()
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
                    if recordingState.cameraOverlayEnabled {
                        let cameraManager = screenRecorder.getCameraManager()
                        if circularCameraWindow == nil {
                            circularCameraWindow = CircularCameraWindow(cameraManager: cameraManager)
                        }
                        
                        let recordingRect = currentRecordingFrame()
                        
                        circularCameraWindow?.show(
                            at: recordingState.cameraOverlayPosition,
                            size: recordingState.cameraOverlaySize,
                            shape: recordingState.cameraOverlayShape,
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

    private func selectRecordingWindow() {
        print("🪟 选择录制窗口...")
        hidePopover()

        windowSelector.selectWindow { [weak self] selectedWindow in
            guard let self = self, let target = selectedWindow else {
                print("❌ 窗口选择被取消")
                return
            }

            print("✅ 选择了录制窗口: \(target.displayName)")
            self.recordingState.recordingMode = .selectedWindow(target)
            self.recordingState.selectedArea = target.frame

            self.startRecording()
        }
    }

    private func currentRecordingFrame() -> CGRect? {
        switch recordingState.recordingMode {
        case .fullScreen:
            return nil
        case .selectedArea(let rect):
            return rect
        case .selectedWindow(let target):
            return target.frame
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
    @ObservedObject var cameraManager: CameraManager
    
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    let onSelectArea: () -> Void
    let onSelectWindow: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HeaderView(recordingState: recordingState)
                    
                    if let permissions = permissionsManager {
                        PermissionsStatusView(permissionsManager: permissions)
                    }
                    
                    RecordingStatusView(recordingState: recordingState)
                    
                    RecordingControlsView(
                        recordingState: recordingState,
                        onStartRecording: onStartRecording,
                        onStopRecording: onStopRecording,
                        onSelectArea: onSelectArea,
                        onSelectWindow: onSelectWindow
                    )
                    
                    SettingsView(recordingState: recordingState, audioManager: audioManager, cameraManager: cameraManager)
                }
                .padding(.top, 14)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider()
            .padding(.horizontal, 12)

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出 FastRecord", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.top, 7)
            .padding(.bottom, 8)
        }
        .frame(width: 320, height: 410)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - 头部视图
struct HeaderView: View {
    @ObservedObject var recordingState: RecordingState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.fill")
                .font(.headline)
                .foregroundStyle(recordingState.isRecording ? .red : .accentColor)

            Text("FastRecord")
                .font(.headline)

            Spacer()

            Text(recordingState.isRecording ? "录制中" : "待机")
                .font(.caption)
                .foregroundStyle(recordingState.isRecording ? .red : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
    }
}

// MARK: - 权限状态视图
struct PermissionsStatusView: View {
    @ObservedObject var permissionsManager: PermissionsManager
    
    var body: some View {
        let missingPermissions = missingPermissions

        if !missingPermissions.isEmpty {
            HStack(spacing: 6) {
                Text("缺少权限")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                ForEach(missingPermissions) { permission in
                    PermissionCompactItem(permission: permission)
                }

                Spacer(minLength: 4)

                Button("授权") {
                    Task {
                        await permissionsManager.requestAllPermissions()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .menuSectionStyle()
        }
    }

    private var missingPermissions: [MissingPermission] {
        var permissions: [MissingPermission] = []

        if !permissionsManager.screenRecordingAuthorized {
            permissions.append(MissingPermission(title: "屏幕", color: .red))
        }
        if !permissionsManager.microphoneAuthorized {
            permissions.append(MissingPermission(title: "麦克风", color: .orange))
        }
        if !permissionsManager.cameraAuthorized {
            permissions.append(MissingPermission(title: "摄像头", color: .orange))
        }

        return permissions
    }
}

private struct MissingPermission: Identifiable {
    let title: String
    let color: Color

    var id: String { title }
}

private struct PermissionCompactItem: View {
    let permission: MissingPermission

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(permission.color)
                .imageScale(.small)

            Text(permission.title)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

// MARK: - 录制状态视图
struct RecordingStatusView: View {
    @ObservedObject var recordingState: RecordingState
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(recordingState.isRecording ? .red : .gray)
                .frame(width: 9, height: 9)
            
            Text(recordingState.isRecording ? "录制中" : "未录制")
                .font(.callout)
            
            Spacer()

            if recordingState.isRecording {
                Text(timeString(from: recordingState.recordingDuration))
                    .font(.callout.monospacedDigit())
            } else {
                Text("准备就绪")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .menuSectionStyle()
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
    let onSelectWindow: () -> Void
    
    var body: some View {
        if recordingState.isRecording {
            Button {
                onStopRecording()
            } label: {
                Label("停止录制", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            HStack(spacing: 8) {
                Button {
                    recordingState.recordingMode = .fullScreen
                    onStartRecording()
                } label: {
                    Label("全屏", systemImage: "display")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onSelectArea()
                } label: {
                    Label("区域", systemImage: "crop")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onSelectWindow()
                } label: {
                    Label("窗口", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - 设置视图
struct SettingsView: View {
    @ObservedObject var recordingState: RecordingState
    @ObservedObject var audioManager: AudioManager
    @ObservedObject var cameraManager: CameraManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("设置")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            Toggle("麦克风", isOn: $recordingState.microphoneEnabled)
                .toggleStyle(.checkbox)
            
            if recordingState.microphoneEnabled {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text("输入设备")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)

                        Picker("", selection: $audioManager.selectedMicrophone) {
                            ForEach(audioManager.availableMicrophones) { device in
                                Text(device.name).tag(device)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(audioManager.isLoading)
                        .frame(maxWidth: .infinity)
                        
                        if audioManager.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    
                    let config = audioManager.getRecommendedAudioConfiguration()
                    Text(config.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 20)
            }
            
            Toggle("系统音频", isOn: $recordingState.systemAudioEnabled)
                .toggleStyle(.checkbox)

            Toggle("摄像头叠加", isOn: $recordingState.cameraOverlayEnabled)
                .toggleStyle(.checkbox)
            
            if recordingState.cameraOverlayEnabled {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Text("摄像头")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)

                        Picker("", selection: $cameraManager.selectedCameraID) {
                            if cameraManager.availableCameras.isEmpty {
                                Text("无可用摄像头").tag("")
                            } else {
                                ForEach(cameraManager.availableCameras) { camera in
                                    Text(camera.name).tag(camera.id)
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(cameraManager.availableCameras.isEmpty || recordingState.isRecording)
                        .frame(maxWidth: .infinity)
                    }

                    HStack(spacing: 7) {
                        Text("形状")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)

                        Picker("", selection: $recordingState.cameraOverlayShape) {
                            ForEach(CameraOverlayShape.allCases, id: \.self) { shape in
                                Text(shape.displayName).tag(shape)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: .infinity)
                    }

                    HStack(spacing: 7) {
                        Text("位置")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)

                        Picker("", selection: $recordingState.cameraOverlayPosition) {
                            ForEach(CameraOverlayPosition.allCases, id: \.self) { position in
                                Text(position.displayName).tag(position)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: .infinity)
                    }

                    HStack(spacing: 7) {
                        Text("大小")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)

                        Picker("", selection: $recordingState.cameraOverlaySize) {
                            ForEach(CameraOverlaySize.allCases, id: \.self) { size in
                                Text(size.displayName).tag(size)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .menuSectionStyle()
        .onAppear {
            cameraManager.refreshCameraDevices()
        }
    }
}

private extension View {
    func menuSectionStyle() -> some View {
        self
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
    }
}
