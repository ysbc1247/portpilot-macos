import SwiftUI

struct CommandPaletteView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var query = ""

    private struct Action: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
        let keywords: String
        let perform: () -> Void
    }

    private var actions: [Action] {
        [
            Action(title: "Refresh listeners", symbol: "arrow.clockwise", keywords: "ports reload") { model.refreshNow(); isPresented = false },
            Action(title: model.isMonitoring ? "Pause monitoring" : "Resume monitoring", symbol: model.isMonitoring ? "pause" : "play", keywords: "toggle") {
                model.isMonitoring ? model.pauseMonitoring() : model.startMonitoring(); isPresented = false
            }
        ]
    }

    private var filtered: [Action] {
        guard !query.isEmpty else { return actions }
        return actions.filter { "\($0.title) \($0.keywords)".localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Type a command or port", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding()
            Divider()
            List(filtered) { action in
                Button(action: action.perform) {
                    Label(action.title, systemImage: action.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 5)
            }
        }
        .frame(width: 520, height: 310)
    }
}

