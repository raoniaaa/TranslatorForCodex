import Cocoa
import ApplicationServices

// One whole-draft write after the quiet period. Never select a fragment, use the
// clipboard, or synthesize keys. Restore the caret once after the editor settles.
final class DraftWriter {
    let element: AXUIElement
    let expected: String
    let result: String
    let inserted: String
    let range: CFRange
    let originalSelection: CFRange
    let isCurrent: () -> Bool
    let completion: (Bool, String) -> Void
    private var finished = false
    private var verified = false
    private var movedCaret = false
    private var started = ProcessInfo.processInfo.systemUptime
    private let inputTypes: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged]
    private var inputCounts: [UInt32] = []

    init(element: AXUIElement, expected: String, result: String, inserted: String, range: CFRange, originalSelection: CFRange, isCurrent: @escaping () -> Bool, completion: @escaping (Bool, String) -> Void) {
        self.element = element; self.expected = expected; self.result = result; self.inserted = inserted
        self.range = range; self.originalSelection = originalSelection
        self.isCurrent = isCurrent; self.completion = completion
    }
    private func inputUnchanged() -> Bool {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        return zip(inputTypes, inputCounts).allSatisfy { kind, count in
            CGEventSource.counterForEventType(.combinedSessionState, eventType: kind) == count &&
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: kind) >= elapsed - 0.01
        }
    }
    private func selected(_ range: CFRange) -> Bool {
        guard let actual = axRange(attribute(element, "AXSelectedTextRange")) else { return false }
        return actual.location == range.location && actual.length == range.length
    }
    private func setSelection(_ range: CFRange) -> Bool {
        var copy = range
        guard let value = AXValueCreate(.cfRange, &copy) else { return false }
        return AXUIElementSetAttributeValue(element, "AXSelectedTextRange" as CFString, value) == .success
    }
    private func finish(_ ok: Bool, _ reason: String = "") {
        guard !finished else { return }; finished = true
        completion(ok, reason)
    }
    func start() {
        guard range.location == 0, range.length == expected.utf16.count, inserted == result else { finish(false, "替换范围无效，已保留原文"); return }
        for name in ["AXValue", "AXSelectedTextRange"] {
            var writable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(element, name as CFString, &writable) == .success, writable.boolValue else { finish(false, "此输入框不支持替换，已保留原文"); return }
        }
        started = ProcessInfo.processInfo.systemUptime
        inputCounts = inputTypes.map { CGEventSource.counterForEventType(.combinedSessionState, eventType: $0) }
        guard isCurrent(), attribute(element, "AXValue") as? String == expected, selected(originalSelection), inputUnchanged() else { finish(false, "输入状态已改变，已保留原文"); return }
        guard AXUIElementSetAttributeValue(element, "AXValue" as CFString, result as CFString) == .success else { finish(false, "写入失败，已保留原文"); return }
        later()
    }
    private func verify() {
        guard !finished else { return }
        let actual = attribute(element, "AXValue") as? String
        if actual == result { verified = true }
        // Stop immediately on user activity or focus/composition changes.
        guard isCurrent(), inputUnchanged() else {
            finish(verified, verified ? "英文已填入，保留当前光标位置" : "输入状态已变化，已停止写入确认")
            return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        guard actual == result else {
            if !verified && actual == expected && elapsed < 0.6 { later(); return }
            finish(false, "写入结果未确认，原稿可在设置中查看"); return
        }
        // Give Chromium time to publish its own selection update before one
        // correction. Never repeatedly pull the caret back to the end.
        if elapsed < 0.2 { later(); return }
        let end = CFRange(location: result.utf16.count, length: 0)
        if movedCaret {
            finish(true, selected(end) ? "" : "英文已填入，请点击文本末尾继续输入")
            return
        }
        if selected(end) { finish(true); return }
        movedCaret = true
        guard setSelection(end) else { finish(true, "英文已填入，请点击文本末尾继续输入"); return }
        later()
    }
    private func later() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.verify() } }
}
