import Foundation

struct RawListener: Equatable, Sendable {
    let pid: Int32
    let processName: String
    let owner: String
    let protocolKind: ListenerProtocol
    let address: String
    let port: UInt16
}

enum LsofFieldParser {
    private struct FileRecord {
        var protocolKind: ListenerProtocol?
        var name: String?
        var tcpState: String?
    }

    static func parse(_ data: Data, defaultProtocol: ListenerProtocol) -> [RawListener] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        var pid: Int32?
        var processName = "Unknown"
        var owner = "Unknown"
        var file: FileRecord?
        var results: [RawListener] = []

        func appendFile() {
            guard
                let pid,
                let file,
                file.tcpState == nil || file.tcpState == "LISTEN",
                let name = file.name,
                let endpoint = parseEndpoint(name)
            else { return }
            results.append(RawListener(
                pid: pid,
                processName: processName,
                owner: owner,
                protocolKind: file.protocolKind ?? defaultProtocol,
                address: endpoint.address,
                port: endpoint.port
            ))
        }

        for rawField in fields {
            let cleaned = rawField.drop { byte in byte == 10 || byte == 13 || byte == 32 || byte == 9 }
            guard let tag = cleaned.first else { continue }
            let value = String(decoding: cleaned.dropFirst(), as: UTF8.self)
            switch tag {
            case Character("p").asciiValue:
                appendFile()
                file = nil
                pid = Int32(value)
            case Character("c").asciiValue:
                processName = value
            case Character("L").asciiValue:
                owner = value
            case Character("f").asciiValue:
                appendFile()
                file = FileRecord()
            case Character("P").asciiValue:
                if file == nil { file = FileRecord() }
                file?.protocolKind = ListenerProtocol(rawValue: value.uppercased())
            case Character("n").asciiValue:
                if file == nil { file = FileRecord() }
                file?.name = value
            case Character("T").asciiValue:
                if value.hasPrefix("ST=") {
                    file?.tcpState = String(value.dropFirst(3))
                }
            default:
                continue
            }
        }
        appendFile()

        var seen = Set<String>()
        return results.filter { seen.insert("\($0.pid):\($0.protocolKind.rawValue):\($0.address):\($0.port)").inserted }
    }

    static func parseEndpoint(_ rawValue: String) -> (address: String, port: UInt16)? {
        let withoutConnection = rawValue.components(separatedBy: "->").first ?? rawValue
        let trimmed = withoutConnection.replacingOccurrences(of: " (LISTEN)", with: "")
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        var address = String(trimmed[..<colon])
        let portText = trimmed[trimmed.index(after: colon)...]
        guard let port = UInt16(portText) else { return nil }
        if address.hasPrefix("[") && address.hasSuffix("]") {
            address.removeFirst()
            address.removeLast()
        }
        return (address.isEmpty ? "*" : address, port)
    }
}

