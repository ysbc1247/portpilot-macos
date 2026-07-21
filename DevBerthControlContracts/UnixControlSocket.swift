import Darwin
import Foundation

public enum ControlSocketPath {
    public static func applicationSupportDirectory(developmentMode: Bool = false) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevBerth", isDirectory: true)
            .appendingPathComponent("IPC", isDirectory: true)
        return developmentMode ? base.appendingPathComponent("Development", isDirectory: true) : base
    }

    public static func socketURL(developmentMode: Bool = false) -> URL {
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["DEVBERTH_CONTROL_SOCKET_PATH"],
           override.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: override, isDirectory: false).standardizedFileURL
        }
#endif
        return applicationSupportDirectory(developmentMode: developmentMode)
            .appendingPathComponent("control.sock", isDirectory: false)
    }
}

public enum ControlSocketError: LocalizedError, Sendable {
    case invalidPath
    case systemCall(name: String, code: Int32)
    case peerRejected
    case frameTooLarge(Int)
    case unexpectedEOF
    case invalidResponse
    case hostAlreadyRunning
    case unsafeExistingPath

    public var errorDescription: String? {
        switch self {
        case .invalidPath: "The local control socket path is invalid or too long."
        case let .systemCall(name, code): "The local control socket failed during \(name): \(String(cString: strerror(code)))."
        case .peerRejected: "The local control peer is not the current user."
        case let .frameTooLarge(size): "The local control frame exceeds the \(size)-byte limit."
        case .unexpectedEOF: "The local control connection closed before a complete response arrived."
        case .invalidResponse: "The local control host returned an invalid response."
        case .hostAlreadyRunning: "A DevBerth control host is already running at this socket path."
        case .unsafeExistingPath: "The control socket path is occupied by an unsafe file or another user."
        }
    }
}

public final class UnixControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    private let socketURL: URL
    private let queue = DispatchQueue(label: "com.ysbc.devberth.control-socket", qos: .userInitiated)
    private let lock = NSLock()
    private var listenerDescriptor: Int32 = -1
    private var isStopped = false
    private var socketDevice: dev_t?
    private var socketInode: ino_t?

    public init(socketURL: URL) {
        self.socketURL = socketURL
    }

    public func start(handler: @escaping Handler) throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            throw ControlSocketError.systemCall(name: "chmod directory", code: errno)
        }
        try prepareSocketPath()

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlSocketError.systemCall(name: "socket", code: errno) }
        try setNoSigPipe(descriptor: descriptor)
        var didBind = false
        do {
            try withSocketAddress(path: socketURL.path) { address, length in
                guard Darwin.bind(descriptor, address, length) == 0 else {
                    throw ControlSocketError.systemCall(name: "bind", code: errno)
                }
            }
            didBind = true
            guard chmod(socketURL.path, mode_t(0o600)) == 0 else {
                throw ControlSocketError.systemCall(name: "chmod socket", code: errno)
            }
            guard Darwin.listen(descriptor, 16) == 0 else {
                throw ControlSocketError.systemCall(name: "listen", code: errno)
            }
        } catch {
            Darwin.close(descriptor)
            if didBind { unlink(socketURL.path) }
            throw error
        }

        var socketInfo = stat()
        guard lstat(socketURL.path, &socketInfo) == 0 else {
            Darwin.close(descriptor)
            unlink(socketURL.path)
            throw ControlSocketError.systemCall(name: "stat socket", code: errno)
        }

        lock.lock()
        listenerDescriptor = descriptor
        socketDevice = socketInfo.st_dev
        socketInode = socketInfo.st_ino
        isStopped = false
        lock.unlock()
        queue.async { [weak self] in self?.acceptLoop(descriptor: descriptor, handler: handler) }
    }

    public func stop() {
        lock.lock()
        guard !isStopped else { lock.unlock(); return }
        isStopped = true
        let descriptor = listenerDescriptor
        let device = socketDevice
        let inode = socketInode
        listenerDescriptor = -1
        socketDevice = nil
        socketInode = nil
        lock.unlock()
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        unlinkSocketIfOwned(device: device, inode: inode)
    }

    deinit { stop() }

    private func acceptLoop(descriptor: Int32, handler: @escaping Handler) {
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            do { try setNoSigPipe(descriptor: client) }
            catch { Darwin.close(client); continue }
            var peerUID = uid_t.max
            var peerGID = gid_t.max
            guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
                Darwin.close(client)
                continue
            }
            Task.detached(priority: .userInitiated) {
                defer { Darwin.close(client) }
                do {
                    let requestData = try SocketFraming.readFrame(from: client)
                    let request = try JSONDecoder.devBerth.decode(ControlRequest.self, from: requestData)
                    let response = await handler(request)
                    let responseData = try JSONEncoder.devBerth.encode(response)
                    try SocketFraming.writeFrame(responseData, to: client)
                } catch {
                    let failure = ControlResponse(
                        requestID: "unreadable-request",
                        snapshotVersion: 0,
                        failure: ControlFailure(code: .invalidArguments, message: error.localizedDescription)
                    )
                    if let data = try? JSONEncoder.devBerth.encode(failure) {
                        try? SocketFraming.writeFrame(data, to: client)
                    }
                }
            }
        }
    }

    private func prepareSocketPath() throws {
        var first = stat()
        guard lstat(socketURL.path, &first) == 0 else {
            if errno == ENOENT { return }
            throw ControlSocketError.systemCall(name: "inspect socket path", code: errno)
        }
        guard first.st_uid == geteuid(), (first.st_mode & S_IFMT) == S_IFSOCK else {
            throw ControlSocketError.unsafeExistingPath
        }

        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw ControlSocketError.systemCall(name: "probe socket", code: errno) }
        defer { Darwin.close(probe) }
        try setNoSigPipe(descriptor: probe)
        let connected = try withSocketAddress(path: socketURL.path) { address, length in
            Darwin.connect(probe, address, length) == 0
        }
        if connected { throw ControlSocketError.hostAlreadyRunning }
        let connectionError = errno
        guard connectionError == ECONNREFUSED || connectionError == ENOENT else {
            throw ControlSocketError.systemCall(name: "probe existing socket", code: connectionError)
        }

        var second = stat()
        guard lstat(socketURL.path, &second) == 0 else {
            if errno == ENOENT { return }
            throw ControlSocketError.systemCall(name: "reinspect socket path", code: errno)
        }
        guard second.st_uid == first.st_uid, second.st_dev == first.st_dev, second.st_ino == first.st_ino,
              (second.st_mode & S_IFMT) == S_IFSOCK else {
            throw ControlSocketError.unsafeExistingPath
        }
        guard unlink(socketURL.path) == 0 else {
            throw ControlSocketError.systemCall(name: "remove stale socket", code: errno)
        }
    }

    private func unlinkSocketIfOwned(device: dev_t?, inode: ino_t?) {
        guard let device, let inode else { return }
        var info = stat()
        guard lstat(socketURL.path, &info) == 0,
              info.st_uid == geteuid(), info.st_dev == device, info.st_ino == inode,
              (info.st_mode & S_IFMT) == S_IFSOCK else { return }
        unlink(socketURL.path)
    }
}

public actor UnixControlClient {
    private let socketURL: URL

    public init(socketURL: URL) {
        self.socketURL = socketURL
    }

    public func send(_ request: ControlRequest) async throws -> ControlResponse {
        let path = socketURL.path
        return try await withCheckedThrowingContinuation { continuation in
            // Socket calls are blocking. Keep them off Swift's cooperative
            // executor so a burst of clients cannot starve the host tasks that
            // must read and answer those same connections.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                    guard descriptor >= 0 else {
                        throw ControlSocketError.systemCall(name: "socket", code: errno)
                    }
                    defer { Darwin.close(descriptor) }
                    try setNoSigPipe(descriptor: descriptor)
                    try withSocketAddress(path: path) { address, length in
                        guard Darwin.connect(descriptor, address, length) == 0 else {
                            throw ControlSocketError.systemCall(name: "connect", code: errno)
                        }
                    }
                    var peerUID = uid_t.max
                    var peerGID = gid_t.max
                    guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
                        throw ControlSocketError.peerRejected
                    }
                    try setDeadline(descriptor: descriptor, deadline: request.deadline)
                    try SocketFraming.writeFrame(JSONEncoder.devBerth.encode(request), to: descriptor)
                    let responseData = try SocketFraming.readFrame(from: descriptor)
                    let response = try JSONDecoder.devBerth.decode(ControlResponse.self, from: responseData)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private enum SocketFraming {
    static func writeFrame(_ data: Data, to descriptor: Int32) throws {
        guard data.count <= ControlProtocolConstants.maximumFrameBytes else {
            throw ControlSocketError.frameTooLarge(ControlProtocolConstants.maximumFrameBytes)
        }
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try writeAll($0, to: descriptor) }
        try data.withUnsafeBytes { try writeAll($0, to: descriptor) }
    }

    static func readFrame(from descriptor: Int32) throws -> Data {
        var length = UInt32(0)
        try withUnsafeMutableBytes(of: &length) { try readAll($0, from: descriptor) }
        let count = Int(UInt32(bigEndian: length))
        guard count <= ControlProtocolConstants.maximumFrameBytes else {
            throw ControlSocketError.frameTooLarge(ControlProtocolConstants.maximumFrameBytes)
        }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { try readAll($0, from: descriptor) }
        return data
    }

    private static func writeAll(_ buffer: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        var written = 0
        while written < buffer.count {
            let result = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
            if result < 0 {
                if errno == EINTR { continue }
                throw ControlSocketError.systemCall(name: "write", code: errno)
            }
            guard result > 0 else { throw ControlSocketError.unexpectedEOF }
            written += result
        }
    }

    private static func readAll(_ buffer: UnsafeMutableRawBufferPointer, from descriptor: Int32) throws {
        var received = 0
        while received < buffer.count {
            let result = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: received), buffer.count - received)
            if result < 0 {
                if errno == EINTR { continue }
                throw ControlSocketError.systemCall(name: "read", code: errno)
            }
            guard result > 0 else { throw ControlSocketError.unexpectedEOF }
            received += result
        }
    }
}

private func withSocketAddress<T>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    let bytes = Array(path.utf8)
    var address = sockaddr_un()
    let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path)
    guard !bytes.isEmpty, bytes.count + 1 <= maximumPathLength else { throw ControlSocketError.invalidPath }
    address.sun_family = sa_family_t(AF_UNIX)
    let length = MemoryLayout<sa_family_t>.size + bytes.count + 1
    address.sun_len = UInt8(length)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        destination.copyBytes(from: bytes)
    }
    return try withUnsafePointer(to: &address) {
        try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(length))
        }
    }
}

private func setDeadline(descriptor: Int32, deadline: Date) throws {
    let remaining = max(0.1, deadline.timeIntervalSinceNow)
    var timeout = timeval(
        tv_sec: Int(remaining),
        tv_usec: Int32((remaining.truncatingRemainder(dividingBy: 1)) * 1_000_000)
    )
    guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
          setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
        throw ControlSocketError.systemCall(name: "setsockopt", code: errno)
    }
}

private func setNoSigPipe(descriptor: Int32) throws {
    var enabled: Int32 = 1
    guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw ControlSocketError.systemCall(name: "setsockopt SO_NOSIGPIPE", code: errno)
    }
}
