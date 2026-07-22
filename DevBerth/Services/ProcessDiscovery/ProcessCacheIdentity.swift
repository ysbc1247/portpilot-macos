import Darwin
import Foundation

struct ProcessCacheIdentity: Hashable, Sendable {
    let pid: Int32
    let uid: UInt32
    let executablePath: String
    let executableFileIdentity: ExecutableFileIdentity
    let startTime: Date
    let commandLineDigest: String
    let parentPID: Int32
    let currentDirectory: String
}

protocol ProcessCacheIdentityReading: Sendable {
    func identity(pid: Int32) -> ProcessCacheIdentity?
}

final class SystemProcessCacheIdentityReader: ProcessCacheIdentityReading, @unchecked Sendable {
    private let fileIdentityReader: any ExecutableFileIdentityReading
    private let lock = NSLock()
    private var argumentBuffer: [UInt8]

    init(fileIdentityReader: any ExecutableFileIdentityReading = SystemExecutableFileIdentityReader()) {
        self.fileIdentityReader = fileIdentityReader
        var argumentLimit: Int32 = 0
        var argumentLimitSize = MemoryLayout<Int32>.size
        var limitQuery = [CTL_KERN, KERN_ARGMAX]
        if sysctl(&limitQuery, 2, &argumentLimit, &argumentLimitSize, nil, 0) != 0
            || argumentLimit <= 0 {
            argumentLimit = 1_048_576
        }
        argumentBuffer = [UInt8](repeating: 0, count: Int(argumentLimit))
    }

    func identity(pid: Int32) -> ProcessCacheIdentity? {
        lock.withLock { identityWhileLocked(pid: pid) }
    }

    private func identityWhileLocked(pid: Int32) -> ProcessCacheIdentity? {
        guard let bsdInfo = bsdInfo(pid: pid) else { return nil }
        guard let executablePath = executablePath(pid: pid),
              let executableFileIdentity = fileIdentityReader.identity(atPath: executablePath),
              let argumentString = commandLine(pid: pid),
              let currentDirectory = currentDirectory(pid: pid) else { return nil }
        return ProcessCacheIdentity(
            pid: pid,
            uid: bsdInfo.uid,
            executablePath: executablePath,
            executableFileIdentity: executableFileIdentity,
            startTime: bsdInfo.startTime,
            commandLineDigest: ProcessFingerprint.digest(commandLine: argumentString),
            parentPID: bsdInfo.parentPID,
            currentDirectory: currentDirectory
        )
    }

    private func bsdInfo(pid: Int32) -> (uid: UInt32, parentPID: Int32, startTime: Date)? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard result == expectedSize else { return nil }
        let seconds = TimeInterval(info.pbi_start_tvsec)
        let microseconds = TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return (
            uid: info.pbi_uid,
            parentPID: Int32(bitPattern: info.pbi_ppid),
            startTime: Date(timeIntervalSince1970: seconds + microseconds)
        )
    }

    private func executablePath(pid: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
        let count = bytes.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard count > 0 else { return nil }
        return bytes.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map(String.init(cString:))
        }
    }

    private func currentDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let expectedSize = MemoryLayout<proc_vnodepathinfo>.stride
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(expectedSize))
        guard result == expectedSize else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    private func commandLine(pid: Int32) -> String? {
        var byteCount = argumentBuffer.count
        var argumentQuery = [CTL_KERN, KERN_PROCARGS2, pid]
        let status = argumentBuffer.withUnsafeMutableBytes { buffer in
            sysctl(&argumentQuery, 3, buffer.baseAddress, &byteCount, nil, 0)
        }
        guard status == 0, byteCount >= MemoryLayout<Int32>.size else { return nil }
        return Self.parseCommandLine(argumentBuffer, byteCount: byteCount)
    }

    static func parseCommandLine(_ data: Data) -> String? {
        parseCommandLine([UInt8](data), byteCount: data.count)
    }

    private static func parseCommandLine(_ bytes: [UInt8], byteCount: Int) -> String? {
        guard byteCount >= MemoryLayout<Int32>.size, byteCount <= bytes.count else { return nil }
        var argumentCount: Int32 = 0
        withUnsafeMutableBytes(of: &argumentCount) { destination in
            bytes.withUnsafeBytes { source in
                _ = memcpy(destination.baseAddress, source.baseAddress, MemoryLayout<Int32>.size)
            }
        }
        guard argumentCount > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < byteCount, bytes[index] != 0 { index += 1 }
        while index < byteCount, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        while index < byteCount, arguments.count < Int(argumentCount) {
            let start = index
            while index < byteCount, bytes[index] != 0 { index += 1 }
            if index > start {
                arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            }
            while index < byteCount, bytes[index] == 0 { index += 1 }
        }
        return arguments.isEmpty ? nil : arguments.joined(separator: "\0")
    }
}
