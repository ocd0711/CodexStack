import AppKit
import SwiftUI
import QuartzCore
import UserNotifications

enum ResetCelebrationKind: Sendable {
    case weekly

    var title: String {
        return NSLocalizedString("Weekly Quota Reset!", bundle: .module, comment: "")
    }

    var subtitle: String {
        return NSLocalizedString("A whole new week of Codex.", bundle: .module, comment: "")
    }

    var emoji: String {
        return "🎊"
    }

    var notificationID: String { "codexstack.celebration.weekly" }
}

@MainActor
final class ResetCelebrationController {
    static let shared = ResetCelebrationController()

    private var confettiWindow: NSWindow?
    private var dismissTask: Task<Void, Never>?
    private var mousePollTask: Task<Void, Never>?

    private init() {}

    func present(kind: ResetCelebrationKind) {
        dismissTask?.cancel()
        mousePollTask?.cancel()

        sendSystemNotification(kind: kind)

        let screen = activeScreen() ?? NSScreen.main
        guard let screen else { return }
        showConfetti(screen: screen)

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.dismissConfetti() }
        }

        // Dismiss confetti on mouse movement after 300ms grace period
        let initialLocation = NSEvent.mouseLocation
        mousePollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000) // 20 Hz
                let p = NSEvent.mouseLocation
                let dx = p.x - initialLocation.x
                let dy = p.y - initialLocation.y
                if dx * dx + dy * dy > 25 {
                    await MainActor.run { [weak self] in self?.dismissConfetti() }
                    return
                }
            }
        }
    }

    // MARK: - System notification

    private func sendSystemNotification(kind: ResetCelebrationKind) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = kind.emoji + " " + kind.title
        content.body = kind.subtitle
        content.sound = .default
        let request = UNNotificationRequest(identifier: kind.notificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Confetti window

    private func showConfetti(screen: NSScreen) {
        let frame = screen.frame
        if let existing = confettiWindow {
            existing.setFrame(frame, display: false)
            existing.alphaValue = 1
            (existing.contentView as? NSHostingView<ConfettiNSViewRepresentable>)?.rootView = ConfettiNSViewRepresentable()
            existing.orderFrontRegardless()
            return
        }
        let win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = NSHostingView(rootView: ConfettiNSViewRepresentable())
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        win.contentView = hosting
        confettiWindow = win
        win.orderFrontRegardless()
    }

    private func dismissConfetti() {
        dismissTask?.cancel()
        dismissTask = nil
        mousePollTask?.cancel()
        mousePollTask = nil
        guard let win = confettiWindow, win.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            win.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            win.orderOut(nil)
            win.contentView = nil
            win.alphaValue = 1
            Task { @MainActor [weak self] in self?.confettiWindow = nil }
        })
    }

    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }
}

// MARK: - Confetti

private struct ConfettiNSViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ConfettiEmitterView()
        view.fire()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private class ConfettiEmitterView: NSView {
    private let emitter = CAEmitterLayer()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(emitter)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: -20)
        emitter.emitterSize = CGSize(width: bounds.width, height: 1)
        emitter.emitterShape = .line
    }

    func fire() {
        emitter.seed = arc4random()
        let colors: [NSColor] = [
            NSColor(red: 1.0, green: 0.2, blue: 0.3, alpha: 1.0),
            NSColor(red: 0.1, green: 0.6, blue: 1.0, alpha: 1.0),
            NSColor(red: 1.0, green: 0.8, blue: 0.1, alpha: 1.0),
            NSColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1.0),
            NSColor(red: 0.6, green: 0.3, blue: 1.0, alpha: 1.0),
            NSColor.white
        ]

        let rectImage = makeConfettiImage(size: CGSize(width: 12, height: 18), cornerRadius: 2)
        let circleImage = makeConfettiImage(size: CGSize(width: 14, height: 14), cornerRadius: 7)

        var cells: [CAEmitterCell] = []
        for color in colors {
            for image in [rectImage, circleImage] {
                let cell = CAEmitterCell()
                cell.contents = image
                cell.color = color.cgColor
                cell.birthRate = 18
                cell.lifetime = 8.0
                cell.velocity = 250
                cell.velocityRange = 100
                cell.emissionLongitude = .pi / 2
                cell.emissionRange = .pi
                cell.spin = 3
                cell.spinRange = 5
                cell.scale = 0.5
                cell.scaleRange = 0.2
                cell.yAcceleration = 350
                cell.xAcceleration = CGFloat.random(in: -40...40)
                cell.alphaSpeed = -0.05
                cells.append(cell)
            }
        }

        emitter.emitterCells = cells
        emitter.beginTime = CACurrentMediaTime()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.emitter.birthRate = 0
        }
    }

    private func makeConfettiImage(size: CGSize, cornerRadius: CGFloat) -> CGImage? {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.set()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: cornerRadius, yRadius: cornerRadius)
        path.fill()
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
