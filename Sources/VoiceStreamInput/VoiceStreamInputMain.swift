import AppKit

@MainActor
private enum AppBootstrap {
    static let delegate = AppDelegate()
}

@main
struct VoiceStreamInputMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = AppBootstrap.delegate
        app.run()
    }
}
