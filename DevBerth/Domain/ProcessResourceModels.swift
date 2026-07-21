import Foundation

struct ProcessResourceUsage: Hashable, Codable, Sendable {
    let cpuPercent: Double
    let residentMemoryBytes: UInt64
    let capturedAt: Date
}
