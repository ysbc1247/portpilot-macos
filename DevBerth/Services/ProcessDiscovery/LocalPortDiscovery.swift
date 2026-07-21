import Foundation

actor LocalPortDiscovery: PortDiscovering {
    private let runner: any CommandRunning
    private let metadataProvider: ProcessMetadataProvider
    private var firstDetected: [String: Date] = [:]
    private struct CachedMetadata {
        let value: ProcessMetadata
        let lsofProcessName: String
        let cachedAt: Date
    }
    private var metadataCache: [Int32: CachedMetadata] = [:]
    private let metadataCacheLifetime: TimeInterval = 30
    private let metadataRefreshBudget = 3

    init(runner: any CommandRunning, includeProjectInference: Bool = true) {
        self.runner = runner
        self.metadataProvider = ProcessMetadataProvider(
            runner: runner,
            inferer: includeProjectInference ? ProjectInferer() : nil
        )
    }

    func discover() async throws -> [NetworkListener] {
        async let tcpResult = runner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-F0pcLftPnT", "+c", "0"]
        )
        async let udpResult = runner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-iUDP", "-F0pcLftPnT", "+c", "0"]
        )
        let (tcp, udp) = try await (tcpResult, udpResult)
        guard tcp.exitCode == 0 || tcp.exitCode == 1 else {
            throw DevBerthError.commandFailed(command: "lsof TCP discovery", status: tcp.exitCode, details: tcp.stderrString)
        }
        guard udp.exitCode == 0 || udp.exitCode == 1 else {
            throw DevBerthError.commandFailed(command: "lsof UDP discovery", status: udp.exitCode, details: udp.stderrString)
        }

        let raw = LsofFieldParser.parse(tcp.stdout, defaultProtocol: .tcp)
            + LsofFieldParser.parse(udp.stdout, defaultProtocol: .udp)
        let grouped = Dictionary(grouping: raw, by: \.pid)
        var metadata: [Int32: ProcessMetadata] = [:]
        let now = Date()
        let refreshPIDs = Set(
            grouped.keys.compactMap { pid -> (Int32, Date)? in
                guard let cached = metadataCache[pid],
                      cached.lsofProcessName == grouped[pid]?.first?.processName,
                      now.timeIntervalSince(cached.cachedAt) >= metadataCacheLifetime else { return nil }
                return (pid, cached.cachedAt)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(metadataRefreshBudget)
            .map(\.0)
        )

        for (pid, listeners) in grouped {
            if let cached = metadataCache[pid],
               !refreshPIDs.contains(pid),
               cached.lsofProcessName == listeners[0].processName {
                metadata[pid] = cached.value
            }
        }

        await withTaskGroup(of: (Int32, ProcessMetadata).self) { group in
            for (pid, listeners) in grouped where metadata[pid] == nil {
                let fallback = listeners[0]
                group.addTask { [metadataProvider] in
                    let value = await metadataProvider.metadata(
                        pid: pid,
                        fallbackName: fallback.processName,
                        fallbackOwner: fallback.owner
                    )
                    return (pid, value)
                }
            }
            for await (pid, value) in group {
                metadata[pid] = value
                metadataCache[pid] = CachedMetadata(
                    value: value,
                    lsofProcessName: grouped[pid]?.first?.processName ?? value.name,
                    cachedAt: now
                )
            }
        }

        metadataCache = metadataCache.filter { grouped[$0.key] != nil }
        let listeners = raw.compactMap { item -> NetworkListener? in
            guard let process = metadata[item.pid] else { return nil }
            let id = "\(item.pid):\(item.protocolKind.rawValue):\(item.address):\(item.port)"
            let first = firstDetected[id] ?? now
            firstDetected[id] = first
            return NetworkListener(
                protocolKind: item.protocolKind,
                address: item.address,
                port: item.port,
                process: process,
                firstDetectedAt: first,
                lastDetectedAt: now
            )
        }
        let currentIDs = Set(listeners.map(\.id))
        firstDetected = firstDetected.filter { currentIDs.contains($0.key) }
        return listeners.sorted {
            $0.port == $1.port ? $0.protocolKind.rawValue < $1.protocolKind.rawValue : $0.port < $1.port
        }
    }
}
