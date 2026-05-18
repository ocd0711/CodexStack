import AppKit
import SwiftUI
import QuartzCore

enum ResetCelebrationKind: Sendable {
    case session
    case weekly

    var title: String {
        switch self {
        case .session:
            return NSLocalizedString("5h Window Reset!", bundle: .module, comment: "")
        case .weekly:
            return NSLocalizedString("Weekly Quota Reset!", bundle: .module, comment: "")
        }
    }

    var subtitle: String {
        switch self {
        case .session:
            return NSLocalizedString("Fresh quota — back to full speed.", bundle: .module, comment: "")
        case .weekly:
            return NSLocalizedString("A whole new week of Codex.", bundle: .module, comment: "")
        }
    }

    var emoji: String {
        switch self {
        case .session: return "🎉"
        case .weekly: return "🎊"
        }
    }

    var accent: Color {
        switch self {
        case .session: return Color(nsColor: .systemTeal)
        case .weekly: return Color(nsColor: .systemPurple)
        }
    }
}

@MainActor
final class ResetCelebrationController {
    static let shared = ResetCelebrationController()

    private var window: NSWindow?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func present(kind: ResetCelebrationKind) {
        dismissTask?.cancel()
        dismissTask = nil

        let screen = activeScreen() ?? NSScreen.main
        guard let screen else { return }

        let frame = screen.frame
        let window: NSWindow
        if let existing = self.window {
            window = existing
            window.setFrame(frame, display: false)
            window.alphaValue = 1
        } else {
            window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            self.window = window
        }

        let view = ResetCelebrationView(kind: kind) { [weak self] in
            self?.dismiss()
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting

        window.orderFrontRegardless()
        window.makeKey()

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.dismiss() }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        if let win = window {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.4
                win.animator().alphaValue = 0
            }, completionHandler: {
                win.orderOut(nil)
                win.contentView = nil
                win.alphaValue = 1
            })
        }
    }

    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }
}

private struct ResetCelebrationView: View {
    let kind: ResetCelebrationKind
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var emojiScale: CGFloat = 0.3
    @State private var emojiRotation: Double = -30

    var body: some View {
        ZStack {
            // Subtle backdrop dimming
            Color.black.opacity(appeared ? 0.3 : 0)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            // High-performance physics confetti layer
            ConfettiNSViewRepresentable()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Central beautifully styled card
            VStack(spacing: 16) {
                Text(kind.emoji)
                    .font(.system(size: 84))
                    .scaleEffect(emojiScale)
                    .rotationEffect(.degrees(emojiRotation))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .padding(.bottom, 6)
                
                VStack(spacing: 6) {
                    Text(kind.title)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    
                    Text(kind.subtitle)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .padding(.bottom, 36)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 40, y: 20)
            .background(
                kind.accent
                    .opacity(appeared ? 0.15 : 0)
                    .blur(radius: 60)
                    .scaleEffect(appeared ? 1.2 : 0.8)
            )
            .scaleEffect(appeared ? 1 : 0.9)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                appeared = true
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.5).delay(0.1)) {
                emojiScale = 1.0
                emojiRotation = 0
            }
        }
    }
}

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
                cell.emissionLongitude = .pi / 2 // pointing down
                cell.emissionRange = .pi // 180 degree spread
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

        // Stop birthing after a burst duration
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
