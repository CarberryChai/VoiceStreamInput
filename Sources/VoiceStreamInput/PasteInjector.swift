import AppKit
import Carbon

@MainActor
final class PasteInjector {
    func inject(_ text: String) async {
        guard !text.isEmpty else {
            return
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let originalInputSourceID = InputSourceManager.currentInputSourceID()
        let shouldSwitchToASCII = InputSourceManager.isCurrentInputSourceCJK()

        if shouldSwitchToASCII {
            _ = InputSourceManager.selectASCIIInputSource()
            try? await Task.sleep(for: .milliseconds(70))
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        try? await Task.sleep(for: .milliseconds(60))

        postPasteShortcut()

        try? await Task.sleep(for: .milliseconds(110))

        if let originalInputSourceID, shouldSwitchToASCII {
            _ = InputSourceManager.selectInputSource(id: originalInputSourceID)
            try? await Task.sleep(for: .milliseconds(50))
        }

        snapshot.restore(to: pasteboard)
    }

    private func postPasteShortcut() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return
        }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
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

        let restoredItems: [NSPasteboardItem] = items.map { payload in
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
    static func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return stringProperty(for: source, key: kTISPropertyInputSourceID)
    }

    static func isCurrentInputSourceCJK() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return false
        }
        return isCJKInputSource(source)
    }

    static func selectASCIIInputSource() -> Bool {
        for candidate in ["com.apple.keylayout.ABC", "com.apple.keylayout.US"] {
            if selectInputSource(id: candidate) {
                return true
            }
        }
        return false
    }

    static func selectInputSource(id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let sourceList = TISCreateInputSourceList(filter, false).takeRetainedValue()
        guard CFArrayGetCount(sourceList) > 0 else {
            return false
        }

        let source = unsafeBitCast(CFArrayGetValueAtIndex(sourceList, 0), to: TISInputSource.self)
        return TISSelectInputSource(source) == noErr
    }

    private static func isCJKInputSource(_ source: TISInputSource) -> Bool {
        if let languages = arrayProperty(for: source, key: kTISPropertyInputSourceLanguages) {
            if languages.contains(where: { $0.hasPrefix("zh") || $0.hasPrefix("ja") || $0.hasPrefix("ko") }) {
                return true
            }
        }

        let fingerprint = [
            stringProperty(for: source, key: kTISPropertyInputSourceID),
            stringProperty(for: source, key: kTISPropertyInputModeID)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        return [
            "scim", "tcim", "pinyin", "zh", "ja", "ko", "kotoeri", "japanese", "korean"
        ]
        .contains(where: fingerprint.contains)
    }

    private static func stringProperty(for source: TISInputSource, key: CFString) -> String? {
        guard let rawPointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }

        return Unmanaged<CFString>.fromOpaque(rawPointer).takeUnretainedValue() as String
    }

    private static func arrayProperty(for source: TISInputSource, key: CFString) -> [String]? {
        guard let rawPointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }

        return Unmanaged<CFArray>.fromOpaque(rawPointer).takeUnretainedValue() as? [String]
    }
}
