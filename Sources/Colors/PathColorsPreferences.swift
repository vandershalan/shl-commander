import SwiftUI

/// Settings → Colours: path fragments and the colour each one gives a folder. Drag rows to
/// reorder; the first fragment from the top that the path contains decides.
struct PathColorsPreferences: View {
    let state: AppState

    @State private var selection: UUID?

    @Environment(\.uiScale) private var scale

    private var store: PathColorStore { state.pathColors }

    var body: some View {
        VStack(alignment: .leading, spacing: scale(8)) {
            Text(
                "Favourites, tabs and path bars take the colour of the first fragment, from the top, that their path contains. Case is ignored; ~ stands for your home folder. Drag rows to reorder."
            )
            .font(.system(size: scale(10)))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach(store.rules) { rule in
                    row(rule).tag(rule.id)
                }
                .onMove { store.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)

            HStack {
                Button {
                    selection = store.add().id
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a fragment")
                Button {
                    if let selection { store.remove(id: selection) }
                    selection = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help("Remove the selected fragment")
                Spacer()
                Button("Reset from Favourites") {
                    store.reset(from: state.favorites.favorites)
                }
            }
        }
        .padding(scale(20))
    }

    private func row(_ rule: PathColorRule) -> some View {
        HStack(spacing: scale(8)) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            ColorGridPicker(selection: rule.color) { color in
                var changed = rule
                changed.color = color
                store.update(changed)
            }
            TextField(
                "Path fragment, e.g. OneDrive",
                text: Binding(
                    get: { rule.pattern },
                    set: { pattern in
                        var changed = rule
                        changed.pattern = pattern
                        store.update(changed)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
    }
}
