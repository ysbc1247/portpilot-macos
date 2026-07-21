import Foundation

struct ProjectStartResult: Sendable {
    let startedProfileIDs: [UUID]
    let durationSeconds: Double
}

typealias ProjectOperationProgressHandler = @Sendable (Int, Int) async -> Void

actor ProjectOrchestrator {
    private let launcher: any LaunchProfileServing

    init(launcher: any LaunchProfileServing) {
        self.launcher = launcher
    }

    func start(
        profiles: [ManagedServiceConfiguration],
        skippingProfileIDs: Set<UUID> = [],
        progress: ProjectOperationProgressHandler? = nil
    ) async throws -> ProjectStartResult {
        let startedAt = Date()
        let layers = try DependencyPlanner.orderedLayers(for: profiles)
        let targetIDs = Set(profiles.map(\.id)).subtracting(skippingProfileIDs)
        var started: [UUID] = []
        await progress?(0, targetIDs.count)
        for layer in layers {
            let targetLayer = layer.filter { targetIDs.contains($0.id) }
            guard !targetLayer.isEmpty else { continue }
            let completed = try await withThrowingTaskGroup(of: UUID.self) { group in
                for profile in targetLayer {
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
            await progress?(started.count, targetIDs.count)
        }
        return ProjectStartResult(startedProfileIDs: started, durationSeconds: Date().timeIntervalSince(startedAt))
    }

    func stop(
        profiles: [ManagedServiceConfiguration],
        skippingProfileIDs: Set<UUID> = [],
        progress: ProjectOperationProgressHandler? = nil
    ) async throws {
        let layers = try DependencyPlanner.orderedLayers(for: profiles)
        let targetIDs = Set(profiles.map(\.id)).subtracting(skippingProfileIDs)
        var completedCount = 0
        await progress?(0, targetIDs.count)
        for layer in layers.reversed() {
            let targetLayer = layer.filter { targetIDs.contains($0.id) }
            guard !targetLayer.isEmpty else { continue }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for profile in targetLayer {
                    group.addTask { [launcher] in
                        try await launcher.stop(profileID: profile.id, timeoutSeconds: profile.shutdownTimeoutSeconds)
                    }
                }
                try await group.waitForAll()
            }
            completedCount += targetLayer.count
            await progress?(completedCount, targetIDs.count)
        }
    }
}
