import AppKit
import Carbon
import CoreGraphics
import Foundation
import IOKit.hidsystem

final class HotkeyMonitor: @unchecked Sendable {
    var triggerKey: RecordingTriggerKey = .rightCommand {
        didSet {
            isTriggerPressed = false
        }
    }
    var onTriggerDown: (() -> Void)?
    var onTriggerUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isTriggerPressed = false

    func start() -> Bool {
        if eventTap == nil {
            let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            }

            if let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) {
                eventTap = tap
                runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

                if let runLoopSource {
                    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
                }

                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }

        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handle(event: event)
            }
        }

        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else {
                    return event
                }
                self.handle(event: event)
                return self.shouldSuppress(event: event) ? nil : event
            }
        }

        if triggerKey.shouldSuppressEvent {
            return eventTap != nil
        }

        return eventTap != nil || globalMonitor != nil || localMonitor != nil
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

        transitionPressedState(triggerKey.isPressed(for: event))
        return triggerKey.shouldSuppressEvent ? nil : Unmanaged.passUnretained(event)
    }

    private func handle(event: NSEvent) {
        guard event.type == .flagsChanged else {
            return
        }

        guard Int64(event.keyCode) == triggerKey.keyCode else {
            return
        }

        transitionPressedState(triggerKey.isPressed(for: event))
    }

    private func shouldSuppress(event: NSEvent) -> Bool {
        guard triggerKey.shouldSuppressEvent else {
            return false
        }

        guard event.type == .flagsChanged else {
            return false
        }

        return Int64(event.keyCode) == triggerKey.keyCode
    }

    private func transitionPressedState(_ isPressed: Bool) {
        guard isPressed != isTriggerPressed else {
            return
        }

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
            return event.flags.rawValue & UInt64(NX_DEVICERCMDKEYMASK) != 0 || event.flags.contains(.maskCommand)
        case .function:
            return event.flags.contains(.maskSecondaryFn)
        }
    }

    func isPressed(for event: NSEvent) -> Bool {
        switch self {
        case .rightCommand:
            return event.modifierFlags.contains(.command)
        case .function:
            return event.modifierFlags.contains(.function)
        }
    }

    var shouldSuppressEvent: Bool {
        switch self {
        case .rightCommand:
            return false
        case .function:
            return true
        }
    }
}
