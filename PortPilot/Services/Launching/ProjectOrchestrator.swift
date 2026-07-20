import Foundation

struct ProjectStartResult: Sendable {
    let startedProfileIDs: [UUID]
    let durationSeconds: Double
}

actor ProjectOrchestrator {
    private let launcher: any LaunchProfileServing

    init(launcher: any LaunchProfileServing) {
        self.launcher = launcher
    }

    func start(profiles: [LaunchProfileConfiguration]) async throws -> ProjectStartResult {
        let startedAt = Date()
        let layers = try DependencyPlanner.orderedLayers(for: profiles)
        var started: [UUID] = []
        for layer in layers {
            let completed = try await withThrowingTaskGroup(of: UUID.self) { group in
                for profile in layer {
                    group.addTask { [launcher] in
                        try await launcher.launch(profile)
                        return profile.id
                    }
                }
                var values: [UUID] = []
                for try await id in group { values.append(id) }
                return values
            }
            started.append(contentsOf: completed)
        }
        return ProjectStartResult(startedProfileIDs: started, durationSeconds: Date().timeIntervalSince(startedAt))
    }

    func stop(profiles: [LaunchProfileConfiguration]) async throws {
        let layers = try DependencyPlanner.orderedLayers(for: profiles)
        for layer in layers.reversed() {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for profile in layer {
                    group.addTask { [launcher] in
                        try await launcher.stop(profileID: profile.id, timeoutSeconds: profile.shutdownTimeoutSeconds)
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}

