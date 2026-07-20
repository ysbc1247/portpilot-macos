import Foundation

actor LocalPortDiscovery: PortDiscovering {
    private let runner: any CommandRunning
    private let metadataProvider: ProcessMetadataProvider
    private var firstDetected: [String: Date] = [:]

    init(runner: any CommandRunning) {
        self.runner = runner
        self.metadataProvider = ProcessMetadataProvider(runner: runner)
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
            throw PortPilotError.commandFailed(command: "lsof TCP discovery", status: tcp.exitCode, details: tcp.stderrString)
        }
        guard udp.exitCode == 0 || udp.exitCode == 1 else {
            throw PortPilotError.commandFailed(command: "lsof UDP discovery", status: udp.exitCode, details: udp.stderrString)
        }

        let raw = LsofFieldParser.parse(tcp.stdout, defaultProtocol: .tcp)
            + LsofFieldParser.parse(udp.stdout, defaultProtocol: .udp)
        let grouped = Dictionary(grouping: raw, by: \.pid)
        var metadata: [Int32: ProcessMetadata] = [:]

        await withTaskGroup(of: (Int32, ProcessMetadata).self) { group in
            for (pid, listeners) in grouped {
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
            for await (pid, value) in group { metadata[pid] = value }
        }

        let now = Date()
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

