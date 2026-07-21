import SwiftUI

enum DevBerthSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 20
    static let xLarge: CGFloat = 28
}

struct StatusDot: View {
    enum Status { case healthy, warning, stopped, failed }
    let status: Status

    private var color: Color {
        switch status {
        case .healthy: .green
        case .warning: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: Text {
        switch status {
        case .healthy: Text("Healthy")
        case .warning: Text("Warning")
        case .stopped: Text("Stopped")
        case .failed: Text("Failed")
        }
    }
}

struct PortBadge: View {
    let port: UInt16
    var body: some View {
        Text(port, format: .number.grouping(.never))
            .font(.system(.body, design: .monospaced, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("Port \(port)")
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action { Button(actionTitle, action: action) }
        }
    }
}

struct InspectorRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

