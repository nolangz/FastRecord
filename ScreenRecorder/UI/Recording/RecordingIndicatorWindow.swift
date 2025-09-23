import Cocoa
import SwiftUI

@MainActor
class RecordingIndicatorWindow: NSObject {
    private var indicatorWindow: NSWindow?
    
    func showIndicator(for recordingRect: CGRect) {
        print("📐 显示录制区域指示器...")
        
        // 如果窗口已存在，先关闭
        hideIndicator()
        
        // 创建比录制区域大一些的窗口，这样边框就在录制区域外
        let lineWidth: CGFloat = 2  // 边框线条宽度
        let safeMargin: CGFloat = 3  // 安全边距
        let margin: CGFloat = lineWidth + safeMargin  // 总边距：线条宽度 + 安全边距
        let indicatorRect = CGRect(
            x: recordingRect.origin.x - margin,
            y: recordingRect.origin.y - margin,
            width: recordingRect.width + margin * 2,
            height: recordingRect.height + margin * 2
        )
        
        // 创建窗口
        indicatorWindow = NSWindow(
            contentRect: indicatorRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        guard let window = indicatorWindow else { return }
        
        // 配置窗口 - 使用合适层级，确保始终可见但不覆盖菜单栏
        window.level = .floating + 1  // 比摄像头窗口稍高一层，确保始终可见
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true  // 完全透明给鼠标事件
        window.isReleasedWhenClosed = false
        
        // 创建虚线边框视图
        let contentView = NSHostingView(
            rootView: RecordingIndicatorView(recordingRect: recordingRect, margin: margin)
                .frame(width: indicatorRect.width, height: indicatorRect.height)
        )
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = contentView
        
        // 显示窗口
        window.orderFrontRegardless()
        
        print("✅ 录制区域指示器已显示: \(recordingRect)")
    }
    
    func hideIndicator() {
        print("📐 隐藏录制区域指示器...")
        indicatorWindow?.close()
        indicatorWindow = nil
    }
    
    func bringToFront() {
        // 确保指示器窗口在最前面
        indicatorWindow?.orderFrontRegardless()
    }
}

// MARK: - 录制指示器视图
struct RecordingIndicatorView: View {
    let recordingRect: CGRect
    let margin: CGFloat
    @State private var animationPhase: Double = 0
    
    var body: some View {
        ZStack {
            Color.clear
            
            // 虚线边框 - 绘制比录制区域稍大的矩形，确保边框在区域外
            let borderRect = CGRect(
                x: 0, y: 0,
                width: recordingRect.width + margin * 2,
                height: recordingRect.height + margin * 2
            )
            
            Rectangle()
                .strokeBorder(
                    Color.blue.opacity(0.8),
                    lineWidth: 2
                )
                .background(Color.clear)
                .frame(width: borderRect.width, height: borderRect.height)
                .overlay(
                    // 手动实现虚线效果
                    DashedRectangle(dashPhase: animationPhase)
                        .stroke(Color.blue.opacity(0.8), lineWidth: 2)
                        .frame(width: borderRect.width, height: borderRect.height)
                )
        }
        .onAppear {
            // 虚线动画效果
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                animationPhase = 12
            }
        }
    }
}

// 手动实现的虚线矩形
struct DashedRectangle: Shape {
    let dashPhase: Double
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let dashLength: CGFloat = 8
        let gapLength: CGFloat = 4
        let _ = dashLength + gapLength
        
        // 顶边
        var currentX: CGFloat = 0
        var shouldDraw = true
        while currentX < rect.width {
            let nextX = min(currentX + (shouldDraw ? dashLength : gapLength), rect.width)
            if shouldDraw {
                path.move(to: CGPoint(x: currentX, y: 0))
                path.addLine(to: CGPoint(x: nextX, y: 0))
            }
            currentX = nextX
            shouldDraw.toggle()
        }
        
        // 简化版本：只画边框轮廓
        path.addRect(rect)
        return path
    }
}