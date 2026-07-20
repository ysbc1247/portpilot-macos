#!/usr/bin/env swift
import Foundation

let iterations = 20
let startedAt = ContinuousClock.now
var totalListeners = 0
for _ in 0..<iterations {
    for arguments in [["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-F0pcLftPnT", "+c", "0"], ["-nP", "-iUDP", "-F0pcLftPnT", "+c", "0"]] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        totalListeners += data.reduce(0) { $1 == Character("n").asciiValue ? $0 + 1 : $0 }
    }
}
let elapsed = ContinuousClock.now - startedAt
let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
print("iterations=\(iterations) elapsed_seconds=\(String(format: "%.3f", seconds)) average_poll_ms=\(String(format: "%.2f", seconds * 1000 / Double(iterations))) parsed_name_fields=\(totalListeners)")

