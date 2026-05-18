import AppKit
import SwiftUI

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
        case .weekly: return Color(nsColor: .systemPink)
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
        window?.orderOut(nil)
        window?.contentView = nil
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

    var body: some View {
        ZStack {
            Color.black.opacity(appeared ? 0.32 : 0)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            ConfettiCanvas(accent: kind.accent)
                .allowsHitTesting(false)

            VStack(spacing: 18) {
                Text(kind.emoji)
                    .font(.system(size: 96))
                    .scaleEffect(appeared ? 1 : 0.5)
                    .rotationEffect(.degrees(appeared ? 0 : -25))
                Text(kind.title)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                Text(kind.subtitle)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(kind.accent.opacity(0.55), lineWidth: 2)
                    )
                    .shadow(color: kind.accent.opacity(0.6), radius: 30)
                    .opacity(appeared ? 1 : 0)
            )
            .scaleEffect(appeared ? 1 : 0.85)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                appeared = true
            }
        }
    }
}

private struct ConfettiCanvas: View {
    let accent: Color
    @State private var pieces: [ConfettiPiece] = ConfettiPiece.generate(count: 110)
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                for piece in pieces {
                    let t = elapsed * piece.speed
                    let progress = (t + piece.phase).truncatingRemainder(dividingBy: 1.6) / 1.6
                    let x = piece.x * size.width + sin((elapsed + piece.phase) * piece.wobble) * 28
                    let y = -40 + CGFloat(progress) * (size.height + 80)
                    let rotation = Angle.degrees((elapsed * 180 + piece.phase * 360) * piece.spin)

                    var ctx = context
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: rotation)
                    let rect = CGRect(x: -piece.size.width / 2, y: -piece.size.height / 2,
                                      width: piece.size.width, height: piece.size.height)
                    let color = piece.useAccent ? accent : piece.color
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
                }
            }
        }
    }
}

private struct ConfettiPiece {
    let x: CGFloat
    let size: CGSize
    let color: Color
    let useAccent: Bool
    let speed: Double
    let phase: Double
    let wobble: Double
    let spin: Double

    static func generate(count: Int) -> [ConfettiPiece] {
        let palette: [Color] = [
            Color(red: 1.00, green: 0.78, blue: 0.20),
            Color(red: 0.36, green: 0.78, blue: 1.00),
            Color(red: 1.00, green: 0.45, blue: 0.65),
            Color(red: 0.55, green: 0.95, blue: 0.55),
            Color(red: 0.78, green: 0.55, blue: 1.00)
        ]
        return (0..<count).map { _ in
            ConfettiPiece(
                x: CGFloat.random(in: 0...1),
                size: CGSize(width: CGFloat.random(in: 6...11), height: CGFloat.random(in: 9...16)),
                color: palette.randomElement() ?? .white,
                useAccent: Bool.random() && Bool.random(),
                speed: Double.random(in: 0.45...0.85),
                phase: Double.random(in: 0...1.6),
                wobble: Double.random(in: 1.4...3.2),
                spin: Double.random(in: 0.6...1.8)
            )
        }
    }
}
