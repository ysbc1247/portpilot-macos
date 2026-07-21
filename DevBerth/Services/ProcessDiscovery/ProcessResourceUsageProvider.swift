import Foundation

protocol ProcessResourceUsageReading: Sendable {
    func read(pids: Set<Int32>) async throws -> [Int32: ProcessResourceUsage]
}

struct SystemProcessResourceUsageReader: ProcessResourceUsageReading, Sendable {
    private let runner: any CommandRunning
    private let clock: @Sendable () -> Date

    init(
        runner: any CommandRunning,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.clock = clock
    }

    func read(pids: Set<Int32>) async throws -> [Int32: ProcessResourceUsage] {
        guard !pids.isEmpty else { return [:] }
        var collected: [Int32: ProcessResourceUsage] = [:]
        let sortedPIDs = pids.sorted()
        for start in stride(from: 0, to: sortedPIDs.count, by: 128) {
            let batch = sortedPIDs[start..<min(start + 128, sortedPIDs.count)]
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: [
                    "-p", batch.map(String.init).joined(separator: ","),
                    "-o", "pid=", "-o", "%cpu=", "-o", "rss="
                ],
                environment: ["LC_ALL": "C"],
                currentDirectory: nil
            )
            guard result.exitCode == 0 || result.exitCode == 1 else {
                throw DevBerthError.commandFailed(
                    command: "process resource inspection",
                    status: result.exitCode,
                    details: result.stderrString
                )
            }
            collected.merge(Self.parse(result.stdoutString, capturedAt: clock())) { _, latest in latest }
        }
        return collected
    }

    static func parse(_ output: String, capturedAt: Date) -> [Int32: ProcessResourceUsage] {
        var values: [Int32: ProcessResourceUsage] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  pid > 0,
                  let cpu = Double(fields[1]),
                  let residentKilobytes = UInt64(fields[2]) else { continue }
            let (bytes, overflow) = residentKilobytes.multipliedReportingOverflow(by: 1_024)
            guard !overflow else { continue }
            values[pid] = ProcessResourceUsage(
                cpuPercent: cpu,
                residentMemoryBytes: bytes,
                capturedAt: capturedAt
            )
        }
        return values
    }
}
