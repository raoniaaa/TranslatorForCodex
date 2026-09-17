import Cocoa

final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Drawing and dragging stay in a nonactivating window so the composer keeps keyboard focus.
final class PetView: NSView {
    var phase = "idle"
    var message = "你好，我是翻译助手"
    var detail = "点击开启 · 拖动挪位置"
    var onClick: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onSettings: (() -> Void)?
    var onPermissions: (() -> Void)?
    var onReset: (() -> Void)?
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var dragged = false
    var dragging = false
    override var acceptsFirstResponder: Bool { false }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation; startOrigin = window?.frame.origin ?? .zero
        dragged = false; dragging = true; NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - startMouse.x, dy = p.y - startMouse.y
        if hypot(dx, dy) > 4 { dragged = true }
        if dragged { window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false; NSCursor.pop()
        if dragged { onDragEnd?() } else { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for (title, action) in [("开启 / 暂停翻译", #selector(toggle)), ("翻译服务设置…", #selector(settings)), ("检查辅助功能权限…", #selector(permissions)), ("回到输入框旁", #selector(reset))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func toggle() { onClick?() }
    @objc private func settings() { onSettings?() }
    @objc private func permissions() { onPermissions?() }
    @objc private func reset() { onReset?() }
    override func draw(_ dirtyRect: NSRect) {
        let busy = ["translating", "applying"].contains(phase)
        let warning = ["error", "permission", "unsupported"].contains(phase)
        let mint = NSColor(calibratedRed: 0.65, green: 0.94, blue: 0.82, alpha: 1)
        let accent = warning ? NSColor(calibratedRed: 1, green: 0.75, blue: 0.43, alpha: 1) : mint
        let ink = NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.14, alpha: 1)
        let t = ProcessInfo.processInfo.systemUptime
        let motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let bob = motion ? sin(t * (busy ? 5 : 2)) * 2 : 0
        func rounded(_ rect: NSRect, _ radius: CGFloat, _ color: NSColor) {
            color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        func oval(_ rect: NSRect, _ color: NSColor) { color.setFill(); NSBezierPath(ovalIn: rect).fill() }
        func line(_ points: [NSPoint], color: NSColor, width: CGFloat) {
            let path = NSBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round; color.setStroke(); path.stroke()
        }
        rounded(NSRect(x: 8, y: 98, width: 232, height: 51), 15, NSColor(calibratedWhite: 0.09, alpha: 0.97))
        let outline = NSBezierPath(roundedRect: NSRect(x: 8.5, y: 98.5, width: 231, height: 50), xRadius: 15, yRadius: 15)
        NSColor.white.withAlphaComponent(0.12).setStroke(); outline.lineWidth = 1; outline.stroke()
        let tail = NSBezierPath(); tail.move(to: NSPoint(x: 116, y: 99)); tail.line(to: NSPoint(x: 124, y: 91)); tail.line(to: NSPoint(x: 132, y: 99)); tail.close()
        NSColor(calibratedWhite: 0.09, alpha: 0.97).setFill(); tail.fill()
        oval(NSRect(x: 21, y: 129, width: 5, height: 5), accent)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (message as NSString).draw(in: NSRect(x: 33, y: 120, width: 195, height: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        (detail as NSString).draw(in: NSRect(x: 21, y: 104, width: 207, height: 17), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(calibratedWhite: 0.66, alpha: 1), .paragraphStyle: paragraph])
        oval(NSRect(x: 93, y: 6, width: 62, height: 8), NSColor.black.withAlphaComponent(0.14))
        // A tiny mint robot, with expressive eyes and little feet.
        rounded(NSRect(x: 101, y: 13 + bob, width: 17, height: 13), 6, accent)
        rounded(NSRect(x: 131, y: 13 + bob, width: 17, height: 13), 6, accent)
        line([NSPoint(x: 124, y: 78 + bob), NSPoint(x: 124, y: 87 + bob)], color: accent, width: 3)
        oval(NSRect(x: 120, y: 85 + bob, width: 8, height: 8), accent)
        rounded(NSRect(x: 83, y: 42 + bob, width: 10, height: 19), 5, accent)
        rounded(NSRect(x: 155, y: 42 + bob, width: 10, height: 19), 5, accent)
        rounded(NSRect(x: 91, y: 23 + bob, width: 66, height: 58), 19, accent)
        rounded(NSRect(x: 98, y: 35 + bob, width: 52, height: 33), 12, ink)
        let blink = motion && t.truncatingRemainder(dividingBy: 4.7) < 0.16
        let sleepy = ["paused", "idle"].contains(phase)
        for x: CGFloat in [110, 133] {
            if phase == "success" {
                line([NSPoint(x: x - 4, y: 51 + bob), NSPoint(x: x, y: 55 + bob), NSPoint(x: x + 4, y: 51 + bob)], color: mint, width: 2.5)
            } else {
                rounded(NSRect(x: x - 3, y: 47 + bob, width: 6, height: blink ? 2 : (sleepy ? 5 : 12)), 3, warning ? accent : mint)
            }
        }
        if busy {
            for i in 0..<3 {
                let alpha = motion ? 0.35 + 0.65 * (sin(t * 6 - Double(i)) + 1) / 2 : 1
                oval(NSRect(x: 173 + CGFloat(i) * 9, y: 48 + bob, width: 4, height: 4), accent.withAlphaComponent(alpha))
            }
        }
        if phase == "composing" {
            rounded(NSRect(x: 111, y: 18 + bob, width: 27, height: 10), 3, ink)
            for i in 0..<4 { rounded(NSRect(x: 114 + CGFloat(i) * 6, y: 22 + bob, width: 3, height: 2), 1, mint) }
        }
    }
}

final class HUD {
    let panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: 248, height: 156), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let pet = PetView(frame: NSRect(x: 0, y: 0, width: 248, height: 156))
    private var savedOrigin: NSPoint?
    private var sessionOrigin: NSPoint?
    private var animation: Timer?
    var isDragging: Bool { pet.dragging }
    init() {
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = pet
        panel.setAccessibilityLabel("Translator 翻译宠物")
        pet.setAccessibilityElement(true); pet.setAccessibilityRole(.button)
        pet.setAccessibilityHelp("点击开启或暂停翻译，拖动移动，右键打开设置")
        if let p = UserDefaults.standard.array(forKey: "translator.pet.origin") as? [Double], p.count == 2 { savedOrigin = NSPoint(x: p[0], y: p[1]) }
        pet.onDragEnd = { [weak self] in
            guard let self = self else { return }
            let p = self.clamp(self.panel.frame.origin)
            self.panel.setFrameOrigin(p); self.savedOrigin = p
            UserDefaults.standard.set([Double(p.x), Double(p.y)], forKey: "translator.pet.origin")
        }
        pet.onReset = { [weak self] in self?.savedOrigin = nil; self?.sessionOrigin = nil; UserDefaults.standard.removeObject(forKey: "translator.pet.origin") }
        animation = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            guard let self = self, self.panel.isVisible else { return }; self.pet.needsDisplay = true
        }
        RunLoop.main.add(animation!, forMode: .common)
    }
    func update(phase: String, message: String, detail: String) {
        pet.phase = phase; pet.message = message; pet.detail = detail
        pet.setAccessibilityLabel("\(message)。\(detail)"); pet.toolTip = "\(message)\n\(detail)\n点击开启 / 暂停 · 拖动移动 · 右键设置"
        pet.needsDisplay = true
    }
    private func clamp(_ p: NSPoint) -> NSPoint {
        let center = NSPoint(x: p.x + 124, y: p.y + 78)
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(center) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSPoint(x: min(max(p.x, visible.minX + 8), visible.maxX - 256), y: min(max(p.y, visible.minY + 8), visible.maxY - 164))
    }
    func show(near rect: CGRect?) {
        guard !pet.dragging else { return }
        let top = NSScreen.screens.first?.frame.maxY ?? 900
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var p = savedOrigin ?? sessionOrigin ?? NSPoint(x: visible.maxX - 270, y: visible.minY + 100)
        if savedOrigin == nil, sessionOrigin == nil, let rect = rect { p = NSPoint(x: rect.maxX - 248, y: top - rect.minY + 8) }
        sessionOrigin = clamp(p)
        panel.setFrameOrigin(clamp(p))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
