import Cocoa
import ApplicationServices

// Used only after an explicit "Go to Codex" action. Never guess between
// multiple editable areas, and never alter the text or selection.
func focusUniqueComposer(in app: NSRunningApplication) -> Bool {
    let root = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.15)
    func editable(_ element: AXUIElement) -> Bool {
        guard attribute(element, "AXRole") as? String == "AXTextArea",
              attribute(element, "AXEnabled") as? Bool != false,
              attribute(element, "AXValue") is String,
              attribute(element, "AXSelectedTextRange") != nil else { return false }
        var writable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &writable) == .success && writable.boolValue
    }
    if let raw = attribute(root, "AXFocusedUIElement") {
        let focused = unsafeBitCast(raw, to: AXUIElement.self)
        if editable(focused) { return true }
    }
    guard let raw = attribute(root, "AXFocusedWindow") else { return false }
    let window = unsafeBitCast(raw, to: AXUIElement.self)
    var candidates: [AXUIElement] = []
    var visited = 0
    var truncated = false
    let deadline = ProcessInfo.processInfo.systemUptime + 0.8
    func visit(_ element: AXUIElement, _ depth: Int) {
        guard candidates.count < 2 else { return }
        guard depth <= 45, visited < 3000, ProcessInfo.processInfo.systemUptime < deadline else { truncated = true; return }
        visited += 1
        if editable(element) {
            if !candidates.contains(where: { CFEqual($0, element) }) { candidates.append(element) }
            return
        }
        for child in attribute(element, "AXChildren") as? [AXUIElement] ?? [] { visit(child, depth + 1) }
    }
    visit(window, 0)
    guard !truncated, candidates.count == 1, visited < 3000, ProcessInfo.processInfo.systemUptime < deadline else { return false }
    return AXUIElementSetAttributeValue(candidates[0], "AXFocused" as CFString, kCFBooleanTrue) == .success
}
