import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum SessionPhase {
        case idle
        case starting
        case listening
        case refining
    }

    private let settings = AppSettings.shared
    private let hotkeyMonitor = HotkeyMonitor()
    private let speechPipeline = SpeechPipeline()
    private let overlayController = RecordingOverlayController()
    private let pasteInjector = PasteInjector()
    private let refiner = LLMRefiner()

    private lazy var settingsWindowController = SettingsWindowController(
        settings: settings,
        refiner: refiner,
        onSave: { [weak self] in
            self?.rebuildMenu()
        }
    )

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var phase: SessionPhase = .idle
    private var isTriggerHeld = false
    private var latestTranscript = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        rebuildMenu()
        preparePermissions()
        startHotkeyMonitor()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.image = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: "VoiceStreamInput")
        button.image?.isTemplate = true
        button.toolTip = "按住 \(settings.recordingTriggerKey.title) 开始语音输入"
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let hintItem = NSMenuItem(title: "按住 \(settings.recordingTriggerKey.title) 开始录音", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)
        menu.addItem(.separator())

        let hotkeyItem = NSMenuItem(title: "录音键", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = makeHotkeyMenu()
        menu.addItem(hotkeyItem)

        let languageItem = NSMenuItem(title: "语言", action: nil, keyEquivalent: "")
        languageItem.submenu = makeLanguageMenu()
        menu.addItem(languageItem)

        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        llmItem.submenu = makeLLMMenu()
        menu.addItem(llmItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.toolTip = "按住 \(settings.recordingTriggerKey.title) 开始语音输入"
    }

    private func makeHotkeyMenu() -> NSMenu {
        let submenu = NSMenu()

        for key in RecordingTriggerKey.allCases {
            let item = NSMenuItem(title: key.title, action: #selector(selectRecordingTriggerKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = settings.recordingTriggerKey == key ? .on : .off
            submenu.addItem(item)
        }

        return submenu
    }

    private func makeLanguageMenu() -> NSMenu {
        let submenu = NSMenu()

        for language in SupportedLanguage.allCases {
            let item = NSMenuItem(title: language.title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = settings.selectedLanguage == language ? .on : .off
            submenu.addItem(item)
        }

        return submenu
    }

    private func makeLLMMenu() -> NSMenu {
        let submenu = NSMenu()

        let toggleItem = NSMenuItem(title: "启用", action: #selector(toggleLLM), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = settings.llmEnabled ? .on : .off
        submenu.addItem(toggleItem)

        submenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        submenu.addItem(settingsItem)

        return submenu
    }

    private func preparePermissions() {
        Task {
            await speechPipeline.primePermissions()
        }

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func startHotkeyMonitor() {
        hotkeyMonitor.triggerKey = settings.recordingTriggerKey
        hotkeyMonitor.onTriggerDown = { [weak self] in
            self?.beginRecording()
        }
        hotkeyMonitor.onTriggerUp = { [weak self] in
            self?.handleFnRelease()
        }

        guard hotkeyMonitor.start() else {
            presentAlert(
                title: "权限不足",
                message: "请在 系统设置 -> 隐私与安全性 中为应用开启辅助功能和输入监控权限，然后重新启动应用。"
            )
            return
        }
    }

    private func beginRecording() {
        guard phase == .idle else {
            return
        }

        isTriggerHeld = true
        phase = .starting
        latestTranscript = ""
        overlayController.showListening()

        Task {
            do {
                try await speechPipeline.start(
                    locale: settings.selectedLanguage.locale,
                    onTranscript: { [weak self] text in
                        self?.latestTranscript = text
                        self?.overlayController.updateTranscript(text)
                    },
                    onLevel: { [weak self] level in
                        self?.overlayController.updateLevel(level)
                    }
                )

                phase = .listening

                if !isTriggerHeld {
                    await finalizeRecording()
                }
            } catch {
                phase = .idle
                overlayController.hide()
                presentAlert(title: "无法开始录音", message: error.localizedDescription)
            }
        }
    }

    private func handleFnRelease() {
        guard phase == .starting || phase == .listening else {
            return
        }

        isTriggerHeld = false

        if phase == .listening {
            Task {
                await finalizeRecording()
            }
        }
    }

    private func finalizeRecording() async {
        guard phase == .listening || phase == .starting else {
            return
        }

        phase = .refining

        let transcript = await speechPipeline.stop()
        let baseText = transcript.isEmpty ? latestTranscript : transcript
        let trimmedText = baseText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty else {
            overlayController.hide()
            phase = .idle
            return
        }

        var finalText = trimmedText

        if let configuration = settings.llmConfigurationIfEnabled {
            overlayController.showRefining()
            do {
                finalText = try await refiner.refine(trimmedText, configuration: configuration)
            } catch {
                finalText = trimmedText
            }
        }

        await pasteInjector.inject(finalText)
        overlayController.hide()
        phase = .idle
    }

    @objc
    private func selectLanguage(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let language = SupportedLanguage(rawValue: rawValue)
        else {
            return
        }

        settings.selectedLanguage = language
        rebuildMenu()
    }

    @objc
    private func selectRecordingTriggerKey(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let key = RecordingTriggerKey(rawValue: rawValue)
        else {
            return
        }

        settings.recordingTriggerKey = key
        hotkeyMonitor.triggerKey = key
        rebuildMenu()
    }

    @objc
    private func toggleLLM() {
        settings.llmEnabled.toggle()
        rebuildMenu()
    }

    @objc
    private func openSettings() {
        settingsWindowController.showWindow(nil)
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }

    private func presentAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
