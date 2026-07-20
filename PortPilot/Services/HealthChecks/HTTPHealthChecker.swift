import Foundation

struct HTTPHealthChecker: HealthChecking, Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func waitUntilHealthy(configuration: HealthCheckConfiguration, timeoutSeconds: Double) async throws {
        let deadline = Date().addingTimeInterval(max(0.1, timeoutSeconds))
        var lastError: Error?
        while Date() < deadline {
            do {
                var request = URLRequest(url: configuration.url)
                request.timeoutInterval = min(5, max(0.5, configuration.intervalSeconds))
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == configuration.expectedStatus { return }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .seconds(max(0.1, configuration.intervalSeconds)))
        }
        if let lastError {
            PortPilotLogger.launching.error("Health check failed: \(lastError.localizedDescription, privacy: .public)")
        }
        throw PortPilotError.healthCheckTimedOut(configuration.url)
    }
}

