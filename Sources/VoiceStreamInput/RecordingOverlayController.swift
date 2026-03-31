import AppKit
import QuartzCore

@MainActor
final class RecordingOverlayController {
    private let minTextWidth: CGFloat = 160
    private let maxTextWidth: CGFloat = 560
    private let panelHeight: CGFloat = 56

    private lazy var panel: NSPanel = makePanel()
    private let waveformView = WaveformBarsView(frame: .zero)
    private let label = NSTextField(labelWithString: "开始说话…")
    private let materialView = NSVisualEffectView(frame: .zero)

    private var labelWidthConstraint: NSLayoutConstraint?
    private var isVisible = false

    func showListening() {
        ensurePanel()
        waveformView.startAnimating()
        updateText("开始说话…", animated: false)
        showPanelIfNeeded()
    }

    func updateTranscript(_ text: String) {
        let displayText = text.isEmpty ? "开始说话…" : text
        updateText(displayText, animated: true)
    }

    func showRefining() {
        updateText("Refining...", animated: true)
    }

    func updateLevel(_ level: CGFloat) {
        waveformView.level = level
    }

    func hide() {
        guard isVisible else {
            return
        }

        waveformView.stopAnimating()
        isVisible = false

        if let layer = materialView.layer {
            let animation = CABasicAnimation(keyPath: "transform.scale")
            animation.fromValue = 1
            animation.toValue = 0.94
            animation.duration = 0.22
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: "hideScale")
            layer.transform = CATransform3DMakeScale(0.94, 0.94, 1)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !self.isVisible else {
                return
            }
            self.panel.orderOut(nil)
            self.materialView.layer?.transform = CATransform3DIdentity
            self.panel.alphaValue = 1
        }
    }

    private func ensurePanel() {
        _ = panel
    }

    private func showPanelIfNeeded() {
        let targetFrame = frame(for: panel.frame.width)
        panel.setFrame(targetFrame, display: true)

        guard !isVisible else {
            return
        }

        isVisible = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        if let layer = materialView.layer {
            layer.transform = CATransform3DMakeScale(0.92, 0.92, 1)
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.92
            spring.toValue = 1
            spring.mass = 0.8
            spring.stiffness = 220
            spring.damping = 18
            spring.initialVelocity = 0.7
            spring.duration = 0.35
            layer.add(spring, forKey: "showScale")
            layer.transform = CATransform3DIdentity
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 1
        }
    }

    private func updateText(_ text: String, animated: Bool) {
        label.stringValue = text

        let width = clampedTextWidth(for: text)
        labelWidthConstraint?.constant = width

        let totalWidth = width + 44 + 14 + 36
        let targetFrame = frame(for: totalWidth)

        if animated, isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.panel.animator().setFrame(targetFrame, display: true)
                self.panel.contentView?.layoutSubtreeIfNeeded()
            }
        } else {
            panel.setFrame(targetFrame, display: true)
            panel.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func clampedTextWidth(for text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: label.font ?? NSFont.systemFont(ofSize: 18, weight: .medium)
        ]
        let measured = ceil((text as NSString).size(withAttributes: attributes).width)
        return min(max(measured, minTextWidth), maxTextWidth)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: frame(for: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        materialView.translatesAutoresizingMaskIntoConstraints = false
        materialView.material = .hudWindow
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 28
        materialView.layer?.masksToBounds = true

        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.setContentHuggingPriority(.required, for: .horizontal)
        waveformView.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .labelColor
        label.maximumNumberOfLines = 1

        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: panel.frame.width, height: panelHeight))
        rootView.autoresizingMask = [.width, .height]
        rootView.wantsLayer = true
        panel.contentView = rootView

        rootView.addSubview(materialView)

        let stack = NSStackView(views: [waveformView, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14

        materialView.addSubview(stack)

        labelWidthConstraint = label.widthAnchor.constraint(equalToConstant: minTextWidth)
        labelWidthConstraint?.isActive = true

        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            materialView.topAnchor.constraint(equalTo: rootView.topAnchor),
            materialView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: materialView.centerYAnchor),

            waveformView.widthAnchor.constraint(equalToConstant: 44),
            waveformView.heightAnchor.constraint(equalToConstant: 32)
        ])

        return panel
    }

    private func frame(for width: CGFloat) -> NSRect {
        let activeScreen = screenForOverlay()
        let visibleFrame = activeScreen.visibleFrame
        let originX = visibleFrame.midX - width / 2
        let originY = visibleFrame.minY + 40
        return NSRect(x: originX, y: originY, width: width, height: panelHeight)
    }

    private func screenForOverlay() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

final class WaveformBarsView: NSView {
    var level: CGFloat = 0

    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private var barLayers: [CALayer] = []
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        for _ in weights {
            let layer = CALayer()
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
            layer.cornerRadius = 2.5
            self.layer?.addSublayer(layer)
            barLayers.append(layer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        redrawBars()
    }

    func startAnimating() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.redrawBars()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
        level = 0
        redrawBars()
    }

    private func redrawBars() {
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let barWidth: CGFloat = 5
        let spacing: CGFloat = 4
        let startX = (bounds.width - (CGFloat(barLayers.count) * barWidth + CGFloat(barLayers.count - 1) * spacing)) / 2
        let maxHeight: CGFloat = 30
        let minHeight: CGFloat = 8

        for (index, barLayer) in barLayers.enumerated() {
            let jitter = CGFloat.random(in: -0.04...0.04)
            let amplitude = max(0.12, min(1, level * weights[index] * (1 + jitter)))
            let height = minHeight + amplitude * (maxHeight - minHeight)
            let originX = startX + CGFloat(index) * (barWidth + spacing)
            let originY = (bounds.height - height) / 2
            barLayer.frame = CGRect(x: originX, y: originY, width: barWidth, height: height)
        }

        CATransaction.commit()
    }
}
