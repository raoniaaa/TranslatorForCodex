import Cocoa
import WebKit
import ApplicationServices
import Carbon

func emit(_ event: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: event), let text = String(data: data, encoding: .utf8) else { return }
    if let backend = backend { backend.send(data) } else { print(text); fflush(stdout) }
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
class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSWindowDelegate {
    var settingsURL: URL?
    let hud = HUD()
    var window: NSWindow?
    var statusItem: NSStatusItem!
    var timer: Timer?
    var hotkeys: [EventHotKeyRef] = []
    var translationHotkey: EventHotKeyRef?
    var shortcutObserver: NSObjectProtocol?
    var translationShortcutActive = false
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
    var writeGeneration = 0
    init(url: URL?) { settingsURL = url; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "译"
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "Translator 设置与试译", action: #selector(showSettings), keyEquivalent: ""); settings.target = self
        let recover = menu.addItem(withTitle: "找回翻译宠物", action: #selector(showPet), keyEquivalent: ""); recover.target = self
        let connect = menu.addItem(withTitle: "前往 Codex（⌃T 翻译）", action: #selector(connectCodex), keyEquivalent: ""); connect.target = self
        let pause = menu.addItem(withTitle: "取消本次翻译", action: #selector(pauseTranslation), keyEquivalent: ""); pause.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Translator", action: #selector(quitApp), keyEquivalent: ""); quit.target = self
        statusItem.menu = menu
        hud.pet.onClick = { [weak self] in
            guard let self = self else { return }
            if self.lastState["configured"] as? Bool != true { self.showSettings(); return }
            self.requestTranslation()
        }
        hud.pet.onSettings = { [weak self] in self?.showSettings() }
        hud.pet.onPermissions = { [weak self] in self?.showPermissions() }
        registerShortcuts()
        timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let input = backend?.commands.fileHandleForReading ?? FileHandle.standardInput
            var buffer = Data()
            while true {
                let chunk = input.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let command = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    DispatchQueue.main.async { self?.handle(command) }
                }
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
        if let key = translationHotkey { UnregisterEventHotKey(key) }
        if let observer = shortcutObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        backend?.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window { NSApp.setActivationPolicy(.accessory) }
    }
    @objc func quitApp() { emit(["type": "quit"]); NSApp.terminate(nil) }
    @objc func pauseTranslation() { emit(["type": "pause"]) }
    @objc func showSettings() {
        guard let settingsURL = settingsURL else { return }
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 830), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Translator · Codex 输入翻译"; w.minSize = NSSize(width: 860, height: 630)
            w.delegate = self; w.isReleasedWhenClosed = false; w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(red: 0.055, green: 0.065, blue: 0.07, alpha: 1)
            let view = WKWebView(frame: w.contentView!.bounds)
            view.autoresizingMask = [.width, .height]; view.navigationDelegate = self
            w.contentView = view; view.load(URLRequest(url: settingsURL)); w.center(); window = w
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let settingsURL = settingsURL, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.host == settingsURL.host && url.port == settingsURL.port && url.path.hasPrefix(settingsURL.path) { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
    @objc func requestTranslation() {
        guard activeWrite == nil else { return }
        var current = sample()
        current["type"] = "translate"
        emit(current)
    }
    @objc func showPet() {
        hud.resetPosition()
        connectCodex()
    }
    @objc func connectCodex() {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.openai.codex" }) else {
            emit(["type":"notice", "reason":"请先打开 Codex，再点击「找回翻译宠物」"])
            return
        }
        // Return to the editor instead of leaving the settings window over it.
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            if AXIsProcessTrusted() { _ = focusUniqueComposer(in: app) }
            self.tick()
        }
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
            if id.id == 1 { owner.requestTranslation() } else { owner.tick(); emit(["type":"undo"]) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        for (key, id) in [(UInt32(kVK_ANSI_R), UInt32(2))] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(key, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x54524E53, id: id), GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference = reference { hotkeys.append(reference) }
            else { emit(["type": "notice", "reason": "快捷键注册失败，请从设置窗口连接 Codex"] ) }
        }
        shortcutObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.updateTranslationShortcut() }
        updateTranslationShortcut()
    }
    // Reserve Control+T only in Codex; other apps keep their own shortcut.
    func updateTranslationShortcut() {
        let active = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex"
        guard active != translationShortcutActive else { return }
        translationShortcutActive = active
        if let key = translationHotkey { UnregisterEventHotKey(key); translationHotkey = nil }
        guard active else { return }
        var key: EventHotKeyRef?
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey), EventHotKeyID(signature: 0x54524E53, id: 1), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &key)
        if result == noErr { translationHotkey = key }
        else { emit(["type":"notice", "reason":"Control + T 已被占用，请点击宠物翻译"] ) }
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
        updateTranslationShortcut()
        guard activeWrite == nil else { renderHUD(); return }
        lastSnapshot = sample()
        let data = try? JSONSerialization.data(withJSONObject: lastSnapshot, options: [.sortedKeys])
        if data != lastSnapshotData { emit(lastSnapshot); lastSnapshotData = data }
        renderHUD()
    }
    func handle(_ command: [String: Any]) {
        switch command["type"] as? String {
        case "settings":
            guard let raw = command["url"] as? String, let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1" else { return }
            settingsURL = url
            showSettings()
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
        case "show-pet": showPet()
        case "cancel-write": writeGeneration += 1
        case "demo": demo()
        default: break
        }
    }
    func replace(_ command: [String: Any]) {
        let id = command["id"] as? NSNumber ?? 0
        func failure(_ reason: String) { emit(["type": "result", "id": id, "ok": false, "reason": reason]) }
        let current = sample()
        guard let el = focusedElement, current["target"] as? String == command["target"] as? String, current["text"] as? String == command["expected"] as? String, current["selectionStart"] as? Int == command["selectionStart"] as? Int, current["selectionLength"] as? Int == command["selectionLength"] as? Int, current["compositionKnown"] as? Bool == true, current["composing"] as? Bool == false, let text = command["text"] as? String else { failure("输入或选词状态已改变，已保留原文"); return }
        guard activeWrite == nil,
              let start = command["replaceStart"] as? Int, let length = command["replaceLength"] as? Int,
              let inserted = command["insertText"] as? String,
              let expected = command["expected"] as? String,
              let target = command["target"] as? String,
              let selection = axRange(attribute(el, "AXSelectedTextRange")) else { failure("缺少替换信息或上次写入尚未结束"); return }
        let generation = writeGeneration
        let writer = DraftWriter(element: el, expected: expected, result: text, inserted: inserted,
            range: CFRange(location: start, length: length), originalSelection: selection,
            isCurrent: { [weak self] in
                guard let self = self, self.writeGeneration == generation else { return false }
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
        let busy = lastState["busy"] as? Bool ?? false
        let phase = lastState["phase"] as? String ?? "idle"
        let codexFocused = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex"
        statusItem.button?.title = busy ? "译·" : "译"
        // Keep the entry point visible even when focus is on a toolbar or button.
        guard hud.isDragging || codexFocused else { hud.panel.orderOut(nil); return }
        if !AXIsProcessTrusted() {
            hud.update(phase: "permission", message: "需要辅助功能权限", detail: "右键检查权限 · 授权后点我翻译")
        } else if lastState["configured"] as? Bool != true {
            hud.update(phase: "idle", message: "先设置翻译服务", detail: "点击设置 · 拖动移动")
        } else {
            let titles = ["idle": "写好后，点我翻译", "ready": "写好后，点我翻译", "waiting-focus": "先点击输入框，再点我", "checking": "正在检查草稿", "composing": "先完成选词，再点我", "translating": "正在翻译整段", "applying": "正在填入英文", "success": "英文已填入", "error": "翻译未完成", "cancelled": "输入已改变 · 点我重试", "editing": "补齐代码块，再点我", "restored": "已恢复原稿", "unsupported": "暂不支持当前输入法"]
            var detail = lastState["message"] as? String ?? "⌃T 翻译整段 · 拖动移动"
            if ["idle", "ready"].contains(phase) { detail = "光标无需移到末尾 · 拖动移动" }
            if phase == "translating" { detail = "\(lastState["model"] as? String ?? "") · " + String(format: "%.1f 秒", Date().timeIntervalSince(phaseStarted)) }
            if phase == "success" { detail = "继续编辑后再点我 · ⌃⌥R 恢复" }
            hud.update(phase: phase, message: titles[phase] ?? "点我翻译当前草稿", detail: detail)
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


let app = NSApplication.shared
var settingsURL: URL?
if CommandLine.arguments.count > 1, let url = URL(string: CommandLine.arguments[1]), url.host == "127.0.0.1" {
    settingsURL = url
} else {
    let service = Backend()
    do { try service.start(); backend = service }
    catch {
        let alert = NSAlert()
        alert.messageText = "Translator 无法启动"
        alert.informativeText = "无法启动翻译服务，请重新安装完整的 Translator.app。"
        alert.runModal()
        exit(1)
    }
}
let delegate = AppDelegate(url: settingsURL)
app.delegate = delegate
app.run()
