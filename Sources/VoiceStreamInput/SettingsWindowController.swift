import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    init(settings: AppSettings, refiner: LLMRefiner, onSave: @escaping () -> Void) {
        let viewController = SettingsViewController(settings: settings, refiner: refiner, onSave: onSave)
        let window = NSWindow(contentViewController: viewController)
        window.title = "LLM Settings"
        window.setContentSize(NSSize(width: 540, height: 220))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class SettingsViewController: NSViewController {
    private let settings: AppSettings
    private let refiner: LLMRefiner
    private let onSave: () -> Void

    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let testButton = NSButton(title: "Test", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    init(settings: AppSettings, refiner: LLMRefiner, onSave: @escaping () -> Void) {
        self.settings = settings
        self.refiner = refiner
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 220))
        view.wantsLayer = true

        baseURLField.stringValue = settings.apiBaseURL
        apiKeyField.stringValue = settings.apiKey
        modelField.stringValue = settings.model

        let grid = NSGridView(views: [
            [makeLabel("API Base URL"), baseURLField],
            [makeLabel("API Key"), apiKeyField],
            [makeLabel("Model"), modelField]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 14
        grid.columnSpacing = 16
        grid.yPlacement = .center
        grid.xPlacement = .fill
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 360

        testButton.target = self
        testButton.action = #selector(runTest)
        testButton.bezelStyle = .rounded

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [testButton, saveButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 12

        view.addSubview(grid)
        view.addSubview(buttons)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),

            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 24)
        ])
    }

    @objc
    private func runTest() {
        let baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKeyField.stringValue
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            !baseURL.isEmpty,
            !apiKey.isEmpty,
            !model.isEmpty,
            let url = URL(string: baseURL)
        else {
            presentAlert(title: "配置不完整", message: "请先填写 API Base URL、API Key 和 Model。")
            return
        }

        let configuration = LLMConfiguration(baseURL: url, apiKey: apiKey, model: model)
        testButton.isEnabled = false

        Task {
            defer { testButton.isEnabled = true }
            do {
                let result = try await refiner.refine("我在写配森接口，还要处理杰森解析", configuration: configuration)
                presentAlert(title: "Test 成功", message: result)
            } catch {
                presentAlert(title: "Test 失败", message: error.localizedDescription)
            }
        }
    }

    @objc
    private func save() {
        settings.apiBaseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.apiKey = apiKeyField.stringValue
        settings.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave()
        view.window?.performClose(nil)
    }

    private func makeLabel(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: view.window ?? NSWindow())
    }
}
