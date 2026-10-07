import SwiftUI

/// Swatch button that opens the palette: neutrals on top, then hues (columns, around the
/// colour wheel) × shades (rows, light → dark). The hovered colour's name is shown below.
struct ColorGridPicker: View {
    let selection: PaletteColor
    let onSelect: (PaletteColor) -> Void

    @State private var isPresented = false
    @State private var hovered: PaletteColor?

    @Environment(\.uiScale) private var scale

    var body: some View {
        Button {
            isPresented = true
        } label: {
            swatch(selection, size: scale(16))
        }
        .buttonStyle(.plain)
        .help("Colour: \(selection.label)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    ForEach(Array(PaletteColor.grid.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(row, id: \.self) { color in
                                cell(color)
                            }
                        }
                        if index == 0 {
                            GridRow { Color.clear.frame(height: 4).gridCellColumns(row.count) }
                        }
                    }
                }
                HStack(spacing: 6) {
                    swatch(hovered ?? selection, size: scale(12))
                    Text((hovered ?? selection).label)
                    Spacer()
                    Text("#" + String(format: "%06X", (hovered ?? selection).hex))
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: scale(11)))
            }
            .padding(12)
        }
    }

    private func cell(_ color: PaletteColor) -> some View {
        Button {
            onSelect(color)
            isPresented = false
        } label: {
            swatch(color, size: scale(20))
                .overlay {
                    if color == selection || color == hovered {
                        Rectangle().strokeBorder(
                            color == selection ? Color.accentColor : Color.primary,
                            lineWidth: 2
                        )
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = color
            } else if hovered == color {
                hovered = nil
            }
        }
    }

    private func swatch(_ color: PaletteColor, size: CGFloat) -> some View {
        Rectangle()
            .fill(color.color)
            .frame(width: size, height: size)
            .overlay(Rectangle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))
    }
}
