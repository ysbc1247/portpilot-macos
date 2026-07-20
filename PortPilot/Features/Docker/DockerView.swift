import SwiftUI

struct DockerView: View {
    var body: some View {
        EmptyStateView(
            symbol: "shippingbox",
            title: "Checking Docker availability",
            message: "PortPilot uses the local Docker CLI when it is installed and the daemon is running. Port monitoring remains available without Docker."
        )
        .navigationTitle("Docker")
    }
}

