import AppKit

@MainActor
final class ScreenGlow {
    enum Mode { case recording, transcribing }

    private var window: NSWindow?
    private var glowView: GlowBorderView?
    private let recordingColor = NSColor(red: 0.6, green: 0.75, blue: 0.85, alpha: 1.0)
    private let transcribingColor = NSColor(red: 0.75, green: 0.65, blue: 0.8, alpha: 1.0)

    init() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame

        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = GlowBorderView(frame: NSRect(origin: .zero, size: frame.size))
        win.contentView = view
        window = win
        glowView = view
    }

    func show(mode: Mode) {
        let color = mode == .recording ? recordingColor : transcribingColor
        glowView?.setColor(color)

        window?.alphaValue = 0
        window?.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window?.animator().alphaValue = 1
        }
        glowView?.startPulsing()
    }

    func hide() {
        glowView?.stopPulsing()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            window?.animator().alphaValue = 0
        }) { [weak self] in
            Task { @MainActor [weak self] in
                self?.window?.orderOut(nil)
            }
        }
    }

    final class GlowBorderView: NSView {
        private var glowColor: NSColor = .orange
        private var pulseTimer: Timer?
        private let topRadius: CGFloat = 18
        private let bottomRadius: CGFloat = 0
        private let glowWidth: CGFloat = 8

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError() }

        func setColor(_ color: NSColor) {
            glowColor = color
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: glowWidth/2, dy: glowWidth/2)
            let path = NSBezierPath()

            path.move(to: NSPoint(x: rect.minX + topRadius, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX - topRadius, y: rect.maxY))
            path.appendArc(withCenter: NSPoint(x: rect.maxX - topRadius, y: rect.maxY - topRadius), radius: topRadius, startAngle: 90, endAngle: 0, clockwise: true)
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY + bottomRadius))
            if bottomRadius > 0 {
                path.appendArc(withCenter: NSPoint(x: rect.maxX - bottomRadius, y: rect.minY + bottomRadius), radius: bottomRadius, startAngle: 0, endAngle: -90, clockwise: true)
            }
            path.line(to: NSPoint(x: rect.minX + bottomRadius, y: rect.minY))
            if bottomRadius > 0 {
                path.appendArc(withCenter: NSPoint(x: rect.minX + bottomRadius, y: rect.minY + bottomRadius), radius: bottomRadius, startAngle: -90, endAngle: -180, clockwise: true)
            }
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY - topRadius))
            path.appendArc(withCenter: NSPoint(x: rect.minX + topRadius, y: rect.maxY - topRadius), radius: topRadius, startAngle: 180, endAngle: 90, clockwise: true)
            path.close()

            path.lineWidth = glowWidth
            glowColor.withAlphaComponent(0.5).setStroke()
            path.stroke()
        }

        func startPulsing() {
            layer?.opacity = 0.7
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let layer = self.layer else { return }
                    let animation = CABasicAnimation(keyPath: "opacity")
                    animation.fromValue = 0.7
                    animation.toValue = 0.35
                    animation.duration = 1.2
                    animation.autoreverses = true
                    layer.add(animation, forKey: "pulse")
                }
            }
            pulseTimer?.fire()
        }

        func stopPulsing() {
            pulseTimer?.invalidate()
            pulseTimer = nil
            layer?.removeAllAnimations()
        }
    }
}
