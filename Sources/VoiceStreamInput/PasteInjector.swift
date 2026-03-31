import AppKit
import ApplicationServices
import Carbon

@MainActor
final class PasteInjector {
    func inject(_ text: String, targetApplication: NSRunningApplication?) async {
        guard !text.isEmpty else {
            return
        }

        let targetApplication = resolveTargetApplication(preferred: targetApplication)
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let originalInputSource = InputSourceManager.currentInputSource()
        let shouldSwitchToASCII = originalInputSource.map { !InputSourceManager.isASCIICapable($0) } ?? false
        let originalFocusedTextContext = FocusedTextContext.capture(in: targetApplication)

        if shouldSwitchToASCII {
            _ = InputSourceManager.selectASCIIInputSource()
            try? await Task.sleep(for: .milliseconds(50))
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        try? await Task.sleep(for: .milliseconds(50))

        activateTargetApplication(targetApplication)
        await waitForFrontmostApplication(targetApplication)
        try? await Task.sleep(for: .milliseconds(80))
        let prefersAppleScript = originalFocusedTextContext.element == nil
        postPasteShortcut(to: targetApplication, prefersAppleScript: prefersAppleScript)

        try? await Task.sleep(for: .milliseconds(300))

        let updatedFocusedTextContext = FocusedTextContext.capture(in: targetApplication)
        if !updatedFocusedTextContext.didLikelyInsert(text, comparedTo: originalFocusedTextContext) {
            if updatedFocusedTextContext.element != nil,
               postPasteShortcutViaAppleScript() {
                try? await Task.sleep(for: .milliseconds(220))
            }

            _ = originalFocusedTextContext.insert(text)
        }

        if shouldSwitchToASCII, let originalInputSource {
            _ = InputSourceManager.selectInputSource(originalInputSource)
        }

        try? await Task.sleep(for: .milliseconds(200))
        snapshot.restore(to: pasteboard)
    }

    private func resolveTargetApplication(preferred: NSRunningApplication?) -> NSRunningApplication? {
        if let preferred,
           !preferred.isTerminated,
           preferred.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            return preferred
        }

        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              !frontmost.isTerminated,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }

        return frontmost
    }

    private func activateTargetApplication(_ application: NSRunningApplication?) {
        guard
            let application,
            !application.isTerminated,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return
        }

        _ = application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func waitForFrontmostApplication(_ application: NSRunningApplication?) async {
        guard let application else {
            return
        }

        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func postPasteShortcut(to application: NSRunningApplication?, prefersAppleScript: Bool) {
        if prefersAppleScript, postPasteShortcutViaAppleScript() {
            return
        }

        if let application, postPasteShortcutViaPID(to: application) {
            return
        }

        if postPasteShortcutViaAppleScript() {
            return
        }

        postPasteShortcutViaCGEvent()
    }

    private func postPasteShortcutViaPID(to application: NSRunningApplication) -> Bool {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return false
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        source.localEventsSuppressionInterval = 0

        let commandDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_Command),
            keyDown: true
        )
        commandDown?.flags = .maskCommand

        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: true
        )
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: false
        )
        keyUp?.flags = .maskCommand

        let commandUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_Command),
            keyDown: false
        )

        guard let commandDown, let keyDown, let keyUp, let commandUp else {
            return false
        }

        commandDown.postToPid(application.processIdentifier)
        keyDown.postToPid(application.processIdentifier)
        keyUp.postToPid(application.processIdentifier)
        commandUp.postToPid(application.processIdentifier)
        return true
    }

    private func postPasteShortcutViaCGEvent() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return
        }

        source.localEventsSuppressionInterval = 0

        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: true
        )
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: false
        )
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func postPasteShortcutViaAppleScript() -> Bool {
        let scriptSource = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """

        let script = NSAppleScript(source: scriptSource)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)

        return error == nil
    }
}

private struct FocusedTextContext {
    let element: AXUIElement?
    let value: String?
    let selectedRange: CFRange?
    let selectedTextSettable: Bool
    let valueSettable: Bool

    static func capture(in application: NSRunningApplication?) -> FocusedTextContext {
        if let application {
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            if let element = focusedElement(from: appElement) {
                return context(for: element)
            }
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        if let element = focusedElement(from: systemWideElement) {
            return context(for: element)
        }

        return FocusedTextContext(
            element: nil,
            value: nil,
            selectedRange: nil,
            selectedTextSettable: false,
            valueSettable: false
        )
    }

    func didLikelyInsert(_ text: String, comparedTo oldContext: FocusedTextContext) -> Bool {
        guard let oldValue = oldContext.value, let currentValue = value else {
            return false
        }

        return currentValue != oldValue && currentValue.contains(text)
    }

    func insert(_ text: String) -> Bool {
        guard let element else {
            return false
        }

        if selectedTextSettable,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            return true
        }

        guard let currentValue = value else {
            return false
        }

        let nsValue = currentValue as NSString
        let totalLength = nsValue.length
        var range = selectedRange ?? CFRange(location: totalLength, length: 0)

        if range.location < 0 || range.location > totalLength {
            range = CFRange(location: totalLength, length: 0)
        }

        if range.length < 0 || range.location + range.length > totalLength {
            range.length = 0
        }

        let replacement = nsValue.replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: text
        )
        guard valueSettable else {
            return false
        }

        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, replacement as CFTypeRef) == .success else {
            return false
        }

        var updatedRange = CFRange(location: range.location + (text as NSString).length, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &updatedRange) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        }

        return true
    }

    private static func focusedElement(from owner: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &value)
        guard
            result == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func context(for element: AXUIElement) -> FocusedTextContext {
        FocusedTextContext(
            element: element,
            value: stringValue(for: element),
            selectedRange: selectedTextRange(for: element),
            selectedTextSettable: isAttributeSettable(element, key: kAXSelectedTextAttribute as CFString),
            valueSettable: isAttributeSettable(element, key: kAXValueAttribute as CFString)
        )
    }

    private static func stringValue(for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private static func selectedTextRange(for element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return range
    }

    private static func isAttributeSettable(_ element: AXUIElement, key: CFString) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, key, &settable) == .success else {
            return false
        }

        return settable.boolValue
    }
}

struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []

        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        guard !items.isEmpty else {
            return
        }

        let restoredItems = items.map { payload in
            let item = NSPasteboardItem()
            for (type, data) in payload {
                item.setData(data, forType: type)
            }
            return item
        }

        pasteboard.writeObjects(restoredItems)
    }
}

enum InputSourceManager {
    static func currentInputSource() -> TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    static func selectASCIIInputSource() -> Bool {
        guard let source = findASCIICapableSource() else {
            return false
        }

        return selectInputSource(source)
    }

    static func selectInputSource(_ source: TISInputSource) -> Bool {
        TISSelectInputSource(source) == noErr
    }

    static func isASCIICapable(_ source: TISInputSource) -> Bool {
        guard let rawPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return false
        }

        let value = Unmanaged<CFBoolean>.fromOpaque(rawPointer).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }

    private static func findASCIICapableSource() -> TISInputSource? {
        let criteria = [
            kTISPropertyInputSourceIsASCIICapable as String: true,
            kTISPropertyInputSourceIsEnabled as String: true
        ] as CFDictionary
        let sourceList = TISCreateInputSourceList(criteria, false).takeRetainedValue()
        let count = CFArrayGetCount(sourceList)
        guard count > 0 else {
            return nil
        }

        var fallback: TISInputSource?

        for index in 0..<count {
            let source = unsafeBitCast(CFArrayGetValueAtIndex(sourceList, index), to: TISInputSource.self)
            fallback = fallback ?? source

            if let inputSourceID = stringProperty(for: source, key: kTISPropertyInputSourceID),
               inputSourceID == "com.apple.keylayout.ABC" || inputSourceID == "com.apple.keylayout.US" {
                return source
            }
        }

        return fallback
    }

    private static func stringProperty(for source: TISInputSource, key: CFString) -> String? {
        guard let rawPointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }

        return Unmanaged<CFString>.fromOpaque(rawPointer).takeUnretainedValue() as String
    }
}
