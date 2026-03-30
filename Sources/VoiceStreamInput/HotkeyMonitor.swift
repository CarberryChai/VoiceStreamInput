import Carbon
import CoreGraphics
import Foundation

final class HotkeyMonitor: @unchecked Sendable {
    var triggerKey: RecordingTriggerKey = .rightCommand
    var onTriggerDown: (() -> Void)?
    var onTriggerUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isTriggerPressed = false

    func start() -> Bool {
        guard eventTap == nil else {
            return true
        }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keycode == triggerKey.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let isPressed = triggerKey.isPressed(for: event)
        if isPressed != isTriggerPressed {
            isTriggerPressed = isPressed
            let onTriggerDown = self.onTriggerDown
            let onTriggerUp = self.onTriggerUp
            DispatchQueue.main.async { [weak self] in
                guard self != nil else {
                    return
                }
                if isPressed {
                    onTriggerDown?()
                } else {
                    onTriggerUp?()
                }
            }
        }

        return nil
    }
}

private extension RecordingTriggerKey {
    var keyCode: Int64 {
        switch self {
        case .rightCommand:
            return Int64(kVK_RightCommand)
        case .function:
            return Int64(kVK_Function)
        }
    }

    func isPressed(for event: CGEvent) -> Bool {
        switch self {
        case .rightCommand:
            return event.flags.contains(.maskCommand)
        case .function:
            return event.flags.contains(.maskSecondaryFn)
        }
    }
}
