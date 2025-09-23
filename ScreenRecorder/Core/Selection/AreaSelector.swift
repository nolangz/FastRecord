import Cocoa

@MainActor
class AreaSelector: NSObject {
    private var overlayWindow: NSWindow?
    private var selectionView: AreaSelectionView?
    private var completion: ((CGRect?) -> Void)?
    
    // 获取鼠标所在的屏幕
    private func getScreenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if NSMouseInRect(mouseLocation, screen.frame, false) {
                return screen
            }
        }
        return nil
    }
    
    func selectArea(completion: @escaping (CGRect?) -> Void) {
        print("🔍 启动区域选择...")
        self.completion = completion
        
        // 获取当前鼠标所在的屏幕
        guard let screen = getScreenWithMouse() ?? NSScreen.main else {
            print("❌ 无法获取屏幕")
            completion(nil)
            return
        }
        
        print("🖥️ 在屏幕上创建选择器: \(screen.localizedName)")
        
        // 创建全屏覆盖窗口
        let screenFrame = screen.frame
        overlayWindow = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        guard let window = overlayWindow else {
            completion(nil)
            return
        }
        
        // 配置窗口
        window.backgroundColor = NSColor.black.withAlphaComponent(0.3)
        window.level = .screenSaver + 1
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // 创建选择视图
        selectionView = AreaSelectionView(frame: screenFrame)
        selectionView?.delegate = self
        window.contentView = selectionView
        
        // 显示窗口
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        print("✅ 区域选择界面已显示")
    }
    
    private func finishSelection(rect: CGRect?) {
        print("📐 区域选择完成: \(rect?.debugDescription ?? "已取消")")
        
        // 隐藏窗口
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        selectionView = nil
        
        // 调用回调
        completion?(rect)
        completion = nil
    }
}

// MARK: - AreaSelectionViewDelegate
extension AreaSelector: AreaSelectionViewDelegate {
    func areaSelectionView(_ view: AreaSelectionView, didSelectArea rect: CGRect) {
        finishSelection(rect: rect)
    }
    
    func areaSelectionViewDidCancel(_ view: AreaSelectionView) {
        finishSelection(rect: nil)
    }
}

// MARK: - 区域选择视图协议
protocol AreaSelectionViewDelegate: AnyObject {
    func areaSelectionView(_ view: AreaSelectionView, didSelectArea rect: CGRect)
    func areaSelectionViewDidCancel(_ view: AreaSelectionView)
}

// MARK: - 区域选择视图
class AreaSelectionView: NSView {
    weak var delegate: AreaSelectionViewDelegate?
    
    private var startPoint: CGPoint?
    private var endPoint: CGPoint?
    private var isSelecting = false
    private var confirmButton: NSButton?
    private var cancelButton: NSButton?
    
    private var selectionRect: CGRect {
        guard let start = startPoint, let end = endPoint else { return .zero }
        
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y) 
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)
        
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupView() {
        // 创建说明标签
        let instructionLabel = NSTextField(labelWithString: "拖拽选择录制区域，按 ESC 取消")
        instructionLabel.textColor = .white
        instructionLabel.font = NSFont.systemFont(ofSize: 16)
        instructionLabel.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        instructionLabel.drawsBackground = true
        instructionLabel.layer?.cornerRadius = 8
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        
        addSubview(instructionLabel)
        
        NSLayoutConstraint.activate([
            instructionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            instructionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 50)
        ])
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // 绘制半透明背景
        NSColor.black.withAlphaComponent(0.3).set()
        dirtyRect.fill()
        
        // 如果有选择区域，绘制选择框
        if !selectionRect.isEmpty {
            // 清除选择区域的背景
            NSColor.clear.set()
            selectionRect.fill()
            
            // 绘制选择框边框
            NSColor.green.setStroke()
            let path = NSBezierPath(rect: selectionRect)
            path.lineWidth = 2.0
            path.stroke()
            
            // 显示尺寸信息
            drawSelectionInfo()
        }
    }
    
    private func drawSelectionInfo() {
        let rect = selectionRect
        guard rect.width > 20 && rect.height > 20 else { return }
        
        let info = String(format: "%.0f × %.0f", rect.width, rect.height)
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.8),
            .font: NSFont.systemFont(ofSize: 12)
        ]
        
        let size = info.size(withAttributes: attributes)
        let infoRect = CGRect(
            x: rect.minX,
            y: rect.minY - size.height - 5,
            width: size.width + 8,
            height: size.height + 4
        )
        
        // 确保信息框在屏幕内
        var adjustedRect = infoRect
        if adjustedRect.minY < 0 {
            adjustedRect.origin.y = rect.maxY + 5
        }
        
        NSColor.black.withAlphaComponent(0.8).set()
        adjustedRect.fill()
        
        info.draw(at: CGPoint(x: adjustedRect.minX + 4, y: adjustedRect.minY + 2), withAttributes: attributes)
    }
    
    private func showConfirmButtons() {
        guard confirmButton == nil else { return }
        
        let rect = selectionRect
        guard rect.width > 50 && rect.height > 50 else { return }
        
        // 确认按钮
        confirmButton = NSButton(title: "开始录制", target: self, action: #selector(confirmSelection))
        confirmButton?.bezelStyle = .rounded
        confirmButton?.translatesAutoresizingMaskIntoConstraints = false
        
        // 取消按钮
        cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelSelection))
        cancelButton?.bezelStyle = .rounded
        cancelButton?.translatesAutoresizingMaskIntoConstraints = false
        
        if let confirmButton = confirmButton, let cancelButton = cancelButton {
            addSubview(confirmButton)
            addSubview(cancelButton)
            
            // 🎯 定位按钮到屏幕居中靠上的位置（固定位置，不随选择区域移动）
            NSLayoutConstraint.activate([
                // 确认按钮 - 屏幕中心偏左
                confirmButton.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -50),
                confirmButton.topAnchor.constraint(equalTo: topAnchor, constant: 100),
                confirmButton.widthAnchor.constraint(equalToConstant: 80),
                
                // 取消按钮 - 屏幕中心偏右
                cancelButton.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 50),
                cancelButton.topAnchor.constraint(equalTo: topAnchor, constant: 100),
                cancelButton.widthAnchor.constraint(equalToConstant: 60)
            ])
        }
    }
    
    private func hideConfirmButtons() {
        confirmButton?.removeFromSuperview()
        cancelButton?.removeFromSuperview()
        confirmButton = nil
        cancelButton = nil
    }
    
    // MARK: - 鼠标事件
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        endPoint = point
        isSelecting = true
        hideConfirmButtons()
        needsDisplay = true
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        
        let point = convert(event.locationInWindow, from: nil)
        endPoint = point
        needsDisplay = true
    }
    
    override func mouseUp(with event: NSEvent) {
        guard isSelecting else { return }
        
        isSelecting = false
        
        // 如果选择区域太小，取消选择
        if selectionRect.width < 20 || selectionRect.height < 20 {
            startPoint = nil
            endPoint = nil
            needsDisplay = true
            return
        }
        
        showConfirmButtons()
        needsDisplay = true
    }
    
    // MARK: - 键盘事件
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC 键
            delegate?.areaSelectionViewDidCancel(self)
        }
    }
    
    override var acceptsFirstResponder: Bool { return true }
    
    // MARK: - 按钮事件
    @objc private func confirmSelection() {
        let rect = selectionRect
        delegate?.areaSelectionView(self, didSelectArea: rect)
    }
    
    @objc private func cancelSelection() {
        delegate?.areaSelectionViewDidCancel(self)
    }
}