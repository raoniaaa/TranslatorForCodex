import Cocoa
import WebKit
import ApplicationServices
import Carbon

func emit(_ event: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: event), let text = String(data: data, encoding: .utf8) else { return }
    print(text); fflush(stdout)
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func axRange(_ value: CFTypeRef?) -> CFRange? {
    guard let value = value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let ax = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(ax) == .cfRange else { return nil }
    var range = CFRange(); return AXValueGetValue(ax, .cfRange, &range) ? range : nil
}
func inputSourceID() -> String {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}
class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let settingsURL: URL
    let hud = HUD()
    var window: NSWindow?
    var statusItem: NSStatusItem!
    var timer: Timer?
    var hotkeys: [EventHotKeyRef] = []
    var focusedElement: AXUIElement?
    var lastTargetElement: AXUIElement?
    var elementToken = 0
    var lastSnapshot: [String: Any] = [:]
    var lastState: [String: Any] = [:]
    var fieldRect: CGRect?
    var phaseStarted = Date()
    var demoUntil = Date.distantPast
    var lastSnapshotData: Data?
    var activeWrite: DraftWriter?
    init(url: URL) { settingsURL = url; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "译"
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "Translator 设置与试译", action: #selector(showSettings), keyEquivalent: ""); settings.target = self
        let connect = menu.addItem(withTitle: "连接 Codex（⌃⌥E）", action: #selector(connectCodex), keyEquivalent: ""); connect.target = self
        let pause = menu.addItem(withTitle: "暂停自动翻译", action: #selector(pauseTranslation), keyEquivalent: ""); pause.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Translator", action: #selector(quitApp), keyEquivalent: ""); quit.target = self
        statusItem.menu = menu
        hud.pet.onClick = { [weak self] in
            guard let self = self else { return }
            if self.lastState["configured"] as? Bool != true { self.showSettings(); return }
            self.tick(); emit(["type": "toggle"])
        }
        hud.pet.onSettings = { [weak self] in self?.showSettings() }
        hud.pet.onPermissions = { [weak self] in self?.showPermissions() }
        registerShortcuts()
        timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let line = readLine() {
                guard let data = line.data(using: .utf8), let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                DispatchQueue.main.async { self?.handle(command) }
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        showSettings()
        tick()
    }
    func installMainMenu() {
        // WKWebView editing shortcuts use AppKit's menu / responder chain.
        // The menu-bar status item's menu is not an application main menu.
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(title: "Translator"); appItem.submenu = appMenu
        let settings = appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "退出 Translator", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        for (title, action, key, shift) in [
            ("撤销", "undo:", "z", false), ("重做", "redo:", "z", true),
            ("剪切", "cut:", "x", false), ("复制", "copy:", "c", false),
            ("粘贴", "paste:", "v", false), ("全选", "selectAll:", "a", false)
        ] {
            let item = edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
            item.keyEquivalentModifierMask = shift ? [.command, .shift] : [.command]
            // A nil target dispatches to the focused WebKit editor.
            item.target = nil
        }
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口"); windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = main
    }
    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.forEach { UnregisterEventHotKey($0) }
    }
    @objc func quitApp() { emit(["type": "quit"]); NSApp.terminate(nil) }
    @objc func pauseTranslation() { emit(["type": "pause"]) }
    @objc func showSettings() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 830), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Translator · Codex 输入翻译"; w.minSize = NSSize(width: 860, height: 630)
            w.isReleasedWhenClosed = false; w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(red: 0.055, green: 0.065, blue: 0.07, alpha: 1)
            let view = WKWebView(frame: w.contentView!.bounds)
            view.autoresizingMask = [.width, .height]; view.navigationDelegate = self
            w.contentView = view; view.load(URLRequest(url: settingsURL)); w.center(); window = w
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.host == settingsURL.host && url.port == settingsURL.port && url.path.hasPrefix(settingsURL.path) { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
    @objc func connectCodex() {
        // Enable even when permission/focus is not ready; the engine waits safely.
        emit(["type": "connect"])
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.openai.codex" }) else { return }
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.tick() }
    }
    @objc func showPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        tick()
        if !AXIsProcessTrusted(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    func registerShortcuts() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event = event, let userData = userData else { return noErr }
            let owner = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            owner.tick(); emit(["type": id.id == 1 ? "toggle" : "undo"])
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        for (key, id) in [(UInt32(kVK_ANSI_E), UInt32(1)), (UInt32(kVK_ANSI_R), UInt32(2))] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(key, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x54524E53, id: id), GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference = reference { hotkeys.append(reference) }
            else { emit(["type": "notice", "reason": "快捷键注册失败，请从设置窗口连接 Codex"] ) }
        }
    }
    func containsRichTokens(_ el: AXUIElement, depth: Int = 0) -> Bool {
        if depth > 4 { return false }
        let role = attribute(el, "AXRole") as? String ?? ""
        if ["AXButton", "AXImage", "AXCheckBox", "AXAttachment"].contains(role) { return true }
        let children = attribute(el, "AXChildren") as? [AXUIElement] ?? []
        return children.prefix(80).contains { containsRichTokens($0, depth: depth + 1) }
    }
    func sample() -> [String: Any] {
        var result: [String: Any] = ["type": "snapshot", "trusted": AXIsProcessTrusted(), "supported": false, "editable": false, "target": "", "guard": ""]
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.openai.codex" else { focusedElement = nil; return result }
        let root = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(root, 0.25)
        guard let raw = attribute(root, "AXFocusedUIElement") else { focusedElement = nil; return result }
        let el = unsafeBitCast(raw, to: AXUIElement.self)
        guard attribute(el, "AXRole") as? String == "AXTextArea", let text = attribute(el, "AXValue") as? String, let selection = axRange(attribute(el, "AXSelectedTextRange")) else { focusedElement = nil; return result }
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(el, "AXValue" as CFString, &writable) == .success, writable.boolValue, !containsRichTokens(el) else { result["reason"] = "当前输入框包含不支持的内容"; focusedElement = nil; return result }
        if lastTargetElement == nil || !CFEqual(lastTargetElement!, el) { elementToken += 1 }
        lastTargetElement = el
        focusedElement = el
        if let rawPoint = attribute(el, "AXPosition"), let rawSize = attribute(el, "AXSize"), CFGetTypeID(rawPoint) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() {
            var point = CGPoint.zero; var size = CGSize.zero
            AXValueGetValue(unsafeBitCast(rawPoint, to: AXValue.self), .cgPoint, &point)
            AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size)
            fieldRect = CGRect(origin: point, size: size)
        }
        let source = inputSourceID()
        let testedSource = source == "com.apple.inputmethod.SCIM.ITABC" || source == "com.apple.keylayout.ABC" || source == "com.apple.keylayout.US"
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        // This is deliberately a conservative popup guard, not a claimed IME composition API.
        let popup = windows?.contains { window in
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            return (window[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) && layer != 0 && layer != 25
        } ?? true
        result.merge(["supported": true, "editable": true, "target": "\(app.processIdentifier):\(elementToken)", "text": text, "selectionStart": selection.location, "selectionLength": selection.length, "atEnd": selection.location == text.utf16.count && selection.length == 0, "compositionKnown": testedSource && windows != nil, "composing": popup, "guard": testedSource ? "候选窗保护 · 实验" : "未适配的输入法"], uniquingKeysWith: { _, new in new })
        return result
    }
    func tick() {
        guard activeWrite == nil else { renderHUD(); return }
        lastSnapshot = sample()
        let data = try? JSONSerialization.data(withJSONObject: lastSnapshot, options: [.sortedKeys])
        if data != lastSnapshotData { emit(lastSnapshot); lastSnapshotData = data }
        renderHUD()
    }
    func handle(_ command: [String: Any]) {
        switch command["type"] as? String {
        case "status":
            if command["phase"] as? String != lastState["phase"] as? String { phaseStarted = Date() }
            lastState = command; renderHUD()
        case "replace": replace(command)
        case "permission": showPermissions()
        case "recheck-permission": tick()
        case "reveal-app":
            let appURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        case "connect": connectCodex()
        case "demo": demo()
        default: break
        }
    }
    func replace(_ command: [String: Any]) {
        let id = command["id"] as? NSNumber ?? 0
        func failure(_ reason: String) { emit(["type": "result", "id": id, "ok": false, "reason": reason]) }
        let current = sample()
        guard let el = focusedElement, current["target"] as? String == command["target"] as? String, current["text"] as? String == command["expected"] as? String, current["selectionStart"] as? Int == command["selectionStart"] as? Int, current["selectionLength"] as? Int == command["selectionLength"] as? Int, current["atEnd"] as? Bool == true, current["compositionKnown"] as? Bool == true, current["composing"] as? Bool == false, let text = command["text"] as? String else { failure("输入或选词状态已改变，已保留原文"); return }
        guard activeWrite == nil,
              let start = command["replaceStart"] as? Int, let length = command["replaceLength"] as? Int,
              let inserted = command["insertText"] as? String,
              let expected = command["expected"] as? String,
              let target = command["target"] as? String,
              let selection = axRange(attribute(el, "AXSelectedTextRange")) else { failure("缺少替换信息或上次写入尚未结束"); return }
        let writer = DraftWriter(element: el, expected: expected, result: text, inserted: inserted,
            range: CFRange(location: start, length: length), originalSelection: selection,
            isCurrent: { [weak self] in
                guard let self = self, self.lastState["armed"] as? Bool == true else { return false }
                let fresh = self.sample()
                return fresh["target"] as? String == target && fresh["trusted"] as? Bool == true && fresh["compositionKnown"] as? Bool == true && fresh["composing"] as? Bool == false
            }, completion: { [weak self] ok, reason in
                guard let self = self else { return }
                self.activeWrite = nil
                emit(["type": "result", "id": id, "ok": ok, "reason": reason])
                self.tick()
            })
        activeWrite = writer; writer.start()
    }

    func renderHUD() {
        guard Date() > demoUntil else { return }
        let armed = lastState["armed"] as? Bool ?? false
        let phase = lastState["phase"] as? String ?? "idle"
        let codexFocused = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex"
        statusItem.button?.title = armed ? "译·" : "译"
        // Visibility follows composer focus, independently of translation being enabled.
        let composerFocused = lastSnapshot["supported"] as? Bool == true
        guard hud.isDragging || (codexFocused && (composerFocused || armed || !AXIsProcessTrusted())) else { hud.panel.orderOut(nil); return }
        if !AXIsProcessTrusted() {
            hud.update(phase: "permission", message: armed ? "已开启 · 等待授权" : "翻译已关闭 · 等待授权", detail: "点击切换 · 右键检查权限")
        } else if !armed && !["error", "unsupported"].contains(phase) {
            let configured = lastState["configured"] as? Bool == true
            hud.update(phase: "paused", message: configured ? "翻译已关闭 · 点我开启" : "先设置翻译服务", detail: "可拖动 · 右键打开设置")
        } else {
            let titles = ["ready": "翻译已开启 · 中文 → 英文", "waiting-focus": "翻译已开启 · 等待输入框", "waiting": "等待输入停顿", "composing": "等待选词完成", "translating": "正在翻译", "applying": "正在填入英文", "success": "英文已填入", "error": "翻译未完成", "paused": "翻译已暂停", "editing": "等待编辑完成", "restored": "已恢复中文", "permission": "翻译已开启 · 等待授权", "unsupported": "暂不支持自动替换"]
            var detail = lastState["message"] as? String ?? "⌃⌥E 暂停 · ⌃⌥R 恢复原文"
            if phase == "translating" { detail = "\(lastState["model"] as? String ?? "") · " + String(format: "%.1f 秒", Date().timeIntervalSince(phaseStarted)) }
            if phase == "success" { detail = "⌘Z 撤销 · ⌃⌥E 暂停" }
            hud.update(phase: phase, message: titles[phase] ?? "Translator", detail: detail)
        }
        hud.show(near: fieldRect)
    }
    func demo() {
        demoUntil = Date().addingTimeInterval(5.5)
        let frames: [(Double, String, String, String)] = [(0, "composing", "演示 · 等待选词", "候选窗出现时暂停翻译"), (1.4, "translating", "演示 · 正在翻译", "这里会显示模型与等待时间"), (3.6, "success", "演示 · 英文已填入", "本次仅演示浮窗，没有调用 API")]
        for (delay, phase, title, detail) in frames {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.hud.update(phase: phase, message: title, detail: detail); self.hud.show(near: nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.6) { self.renderHUD() }
    }
}


guard CommandLine.arguments.count > 1, let url = URL(string: CommandLine.arguments[1]), url.host == "127.0.0.1" else { exit(1) }
let app = NSApplication.shared
let delegate = AppDelegate(url: url)
app.delegate = delegate
app.run()
