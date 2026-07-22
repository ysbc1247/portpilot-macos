import Foundation

struct ProcessResourceUsage: Hashable, Codable, Sendable {
    let cpuPercent: Double
    let residentMemoryBytes: UInt64
    let capturedAt: Date
}

extension Dictionary where Key == Int32, Value == ProcessResourceUsage {
    func isMeaningfullyDifferent(from previous: Self) -> Bool {
        guard Set(keys) == Set(previous.keys) else { return true }
        return contains { pid, current in
            guard let old = previous[pid] else { return true }
            let memoryDelta = current.residentMemoryBytes > old.residentMemoryBytes
                ? current.residentMemoryBytes - old.residentMemoryBytes
                : old.residentMemoryBytes - current.residentMemoryBytes
            let relativeMemoryThreshold = UInt64(Double(old.residentMemoryBytes) * 0.05)
            return abs(current.cpuPercent - old.cpuPercent) >= 1
                || memoryDelta >= Swift.max(1_048_576, relativeMemoryThreshold)
        }
    }
}
