import AppKit

enum StatusIconRenderer {
    private static let size = NSSize(width: 18, height: 18)
    private static let scale: CGFloat = 2

    static func makeIcon(
        sessionUsedRatio: Double?,
        weeklyUsedRatio: Double?,
        progressMode: UtilizationProgressMode
    ) -> NSImage {
        renderImage {
            let sessionPercent = displayPercent(from: sessionUsedRatio, progressMode: progressMode)
            let weeklyPercent = weeklyUsedRatio == nil ? nil : displayPercent(from: weeklyUsedRatio, progressMode: progressMode)

            let barWidth = 30
            let barX = 3
            let top = PixelRect(x: barX, y: 19, width: barWidth, height: 12)
            let bottom = PixelRect(x: barX, y: 5, width: barWidth, height: 8)
            let single = PixelRect(x: barX, y: 10, width: barWidth, height: 16)

            if let weeklyPercent {
                drawCapsule(top, percent: sessionPercent, face: true, alpha: 1)
                drawCapsule(bottom, percent: weeklyPercent, face: false, alpha: 0.92)
            } else {
                drawCapsule(single, percent: sessionPercent, face: true, alpha: 1)
            }
        }
    }

    private static func displayPercent(from usedRatio: Double?, progressMode: UtilizationProgressMode) -> Double? {
        guard let usedRatio else { return nil }
        let clamped = min(1, max(0, usedRatio))
        let value = progressMode == .used ? clamped : 1 - clamped
        return value * 100
    }

    private static func drawCapsule(_ rect: PixelRect, percent: Double?, face: Bool, alpha: CGFloat) {
        let base = NSColor.labelColor
        let fill = base.withAlphaComponent(alpha)
        let trackPath = NSBezierPath(
            roundedRect: rect.cgRect,
            xRadius: CGFloat(rect.height) / scale / 2,
            yRadius: CGFloat(rect.height) / scale / 2
        )

        base.withAlphaComponent(0.26 * alpha).setFill()
        trackPath.fill()

        let strokeRect = PixelRect(
            x: rect.x + 1,
            y: rect.y + 1,
            width: max(0, rect.width - 2),
            height: max(0, rect.height - 2)
        )
        let strokePath = NSBezierPath(
            roundedRect: strokeRect.cgRect,
            xRadius: CGFloat(strokeRect.height) / scale / 2,
            yRadius: CGFloat(strokeRect.height) / scale / 2
        )
        strokePath.lineWidth = 1
        base.withAlphaComponent(0.44 * alpha).setStroke()
        strokePath.stroke()

        if let percent {
            let clamped = min(100, max(0, percent)) / 100
            let fillWidth = Int((Double(rect.width) * clamped).rounded())
            if fillWidth > 0 {
                NSGraphicsContext.current?.cgContext.saveGState()
                trackPath.addClip()
                fill.setFill()
                NSBezierPath(
                    rect: PixelRect(
                        x: rect.x,
                        y: rect.y,
                        width: min(rect.width, fillWidth),
                        height: rect.height
                    ).cgRect
                ).fill()
                NSGraphicsContext.current?.cgContext.restoreGState()
            }
        }

        guard face else { return }
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        ctx?.setShouldAntialias(false)
        ctx?.setBlendMode(.clear)
        let eyeSize = 4
        let eyeOffset = 7
        let centerX = rect.x + rect.width / 2
        let centerY = rect.y + rect.height / 2
        ctx?.fill(PixelRect(x: centerX - eyeOffset - eyeSize / 2, y: centerY - eyeSize / 2, width: eyeSize, height: eyeSize).cgRect)
        ctx?.fill(PixelRect(x: centerX + eyeOffset - eyeSize / 2, y: centerY - eyeSize / 2, width: eyeSize, height: eyeSize).cgRect)
        ctx?.setBlendMode(.normal)
        ctx?.restoreGState()

        let hat = PixelRect(x: centerX - 9, y: rect.y + rect.height - 4, width: 18, height: 4)
        fill.setFill()
        NSBezierPath(rect: hat.cgRect).fill()
    }

    private static func renderImage(_ draw: () -> Void) -> NSImage {
        let image = NSImage(size: size)
        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) {
            rep.size = size
            image.addRepresentation(rep)
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = context
                draw()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        image.isTemplate = true
        return image
    }

    private struct PixelRect {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        var cgRect: CGRect {
            CGRect(
                x: CGFloat(x) / StatusIconRenderer.scale,
                y: CGFloat(y) / StatusIconRenderer.scale,
                width: CGFloat(width) / StatusIconRenderer.scale,
                height: CGFloat(height) / StatusIconRenderer.scale
            )
        }
    }
}
