import Foundation

struct ProcessResourceUsage: Hashable, Sendable {
    let cpuPercent: Double
    let residentMemoryBytes: UInt64
    let capturedAt: Date
}

