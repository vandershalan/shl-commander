import AppKit

/// Draws the app icon: two panes, the left one active, on a rounded slate tile.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = size

    let inset = s * 0.08
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = s * 0.20

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.28, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.15, alpha: 1),
    ])!
    let body = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    gradient.draw(in: body, angle: -90)

    // Two panes.
    let pad = s * 0.10
    let top = s * 0.14
    let inner = tile.insetBy(dx: pad, dy: pad)
    let paneGap = s * 0.035
    let paneWidth = (inner.width - paneGap) / 2
    let paneRect = { (x: CGFloat) in
        NSRect(x: x, y: inner.minY, width: paneWidth, height: inner.height - top * 0.4)
    }

    let accent = NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.98, alpha: 1)

    for (index, x) in [inner.minX, inner.minX + paneWidth + paneGap].enumerated() {
        let rect = paneRect(x)
        let pane = NSBezierPath(roundedRect: rect, xRadius: s * 0.035, yRadius: s * 0.035)
        NSColor(calibratedWhite: 1, alpha: index == 0 ? 0.16 : 0.09).setFill()
        pane.fill()
        if index == 0 {
            accent.setStroke()
            pane.lineWidth = s * 0.018
            pane.stroke()
        }

        // Header strip.
        let header = NSRect(x: rect.minX, y: rect.maxY - s * 0.06, width: rect.width, height: s * 0.06)
        NSColor(calibratedWhite: 1, alpha: index == 0 ? 0.22 : 0.14).setFill()
        NSBezierPath(rect: header).fill()

        // File rows.
        let rowHeight = s * 0.045
        let rowGap = s * 0.028
        var y = rect.maxY - s * 0.06 - rowGap - rowHeight
        var row = 0
        while y > rect.minY + rowGap {
            let width = rect.width * (row % 3 == 0 ? 0.72 : row % 3 == 1 ? 0.55 : 0.63)
            let bar = NSRect(x: rect.minX + s * 0.03, y: y, width: width, height: rowHeight)
            if index == 0 && row == 1 {
                accent.withAlphaComponent(0.85).setFill()
            } else {
                NSColor(calibratedWhite: 1, alpha: index == 0 ? 0.42 : 0.26).setFill()
            }
            NSBezierPath(roundedRect: bar, xRadius: rowHeight / 2, yRadius: rowHeight / 2).fill()
            y -= rowHeight + rowGap
            row += 1
        }
    }

    image.unlockFocus()
    return image
}

let outputDirectory = CommandLine.arguments[1]
let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

for (pixels, name) in sizes {
    let image = drawIcon(size: CGFloat(pixels))
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(name).png"))
}
print("wrote \(sizes.count) sizes")
