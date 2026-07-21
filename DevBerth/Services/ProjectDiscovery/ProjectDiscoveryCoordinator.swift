import Foundation

protocol ProjectDiscoveryAdapting: Sendable {
    var identifier: String { get }
    func discover(in rootURL: URL) throws -> ProjectDiscoveryFinding?
}

struct ProjectDiscoveryCoordinator: Sendable {
    let adapters: [any ProjectDiscoveryAdapting]

    init(adapters: [any ProjectDiscoveryAdapting] = Self.defaultAdapters) {
        self.adapters = adapters
    }

    func discover(at rootURL: URL, discoveredAt: Date = Date()) throws -> ProjectDiscoveryReport {
        let root = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw ProjectDiscoveryError.rootDoesNotExist(root.path)
        }
        guard isDirectory.boolValue else {
            throw ProjectDiscoveryError.rootIsNotDirectory(root.path)
        }
        let findings = try adapters.compactMap { try $0.discover(in: root) }
        return ProjectDiscoveryReport(rootPath: root.path, findings: findings, discoveredAt: discoveredAt)
    }

    static let defaultAdapters: [any ProjectDiscoveryAdapting] = [
        DevBerthManifestDiscoveryAdapter(),
        JavaScriptProjectDiscoveryAdapter(),
        GradleProjectDiscoveryAdapter(),
        MavenProjectDiscoveryAdapter(),
        PythonProjectDiscoveryAdapter(),
        GoProjectDiscoveryAdapter(),
        CargoProjectDiscoveryAdapter(),
        DockerComposeProjectDiscoveryAdapter(),
        ProcfileProjectDiscoveryAdapter(),
        ProcessComposeProjectDiscoveryAdapter(),
        ProjectMarkerDiscoveryAdapter()
    ]
}

actor LocalProjectDiscoveryService: ProjectDiscoveryServing {
    private let coordinator: ProjectDiscoveryCoordinator

    init(coordinator: ProjectDiscoveryCoordinator = ProjectDiscoveryCoordinator()) {
        self.coordinator = coordinator
    }

    func discover(at rootURL: URL) async throws -> ProjectDiscoveryReport {
        try coordinator.discover(at: rootURL)
    }
}

enum ProjectDiscoveryFileReader {
    static let maximumBytes = 1_048_576

    static func firstExisting(_ names: [String], in rootURL: URL) -> URL? {
        names.lazy
            .map { rootURL.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func existing(_ names: [String], in rootURL: URL) -> [URL] {
        names.map { rootURL.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func data(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? maximumBytes + 1) <= maximumBytes else {
            throw ProjectDiscoveryError.unsafeFile(url.path)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    static func text(at url: URL) throws -> String {
        let value = String(decoding: try data(at: url), as: UTF8.self)
        guard !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ProjectDiscoveryError.malformedFile(path: url.path, reason: "the file contains binary data")
        }
        return value
    }
}

enum ProjectDiscoveryParsing {
    static func inferredPorts(in text: String) -> [UInt16] {
        let patterns = [
            #"(?:--port(?:=|\s+)|-p\s+)([0-9]{2,5})"#,
            #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):([0-9]{2,5})"#
        ]
        return uniquePorts(patterns.flatMap { captures(pattern: $0, text: text) })
    }

    static func composeHostPorts(in text: String) -> [UInt16] {
        let quoted = captures(pattern: #"[\"']?([0-9]{2,5}):[0-9]{2,5}(?:/(?:tcp|udp))?[\"']?"#, text: text)
        return uniquePorts(quoted)
    }

    static func captures(pattern: String, text: String, group: Int = 1) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard group < match.numberOfRanges,
                  let capture = Range(match.range(at: group), in: text) else { return nil }
            return String(text[capture])
        }
    }

    static func uniquePorts(_ values: [String]) -> [UInt16] {
        Array(Set(values.compactMap(UInt16.init))).sorted()
    }

    static func evidence(
        path: String,
        detail: String,
        confidence: EvidenceConfidence = .stronglyInferred
    ) -> ProjectDiscoveryEvidence {
        ProjectDiscoveryEvidence(path: path, detail: detail, confidence: confidence)
    }
}

struct ProjectMarkerDiscoveryAdapter: ProjectDiscoveryAdapting {
    let identifier = "project-markers"
    private let markers = [
        ".git", "pnpm-workspace.yaml", "turbo.json", "nx.json", "vite.config.js",
        "vite.config.ts", "vite.config.mjs", "next.config.js", "next.config.mjs",
        "next.config.ts", ".devcontainer", "Makefile", "Taskfile.yml"
    ]

    func discover(in rootURL: URL) throws -> ProjectDiscoveryFinding? {
        let files = ProjectDiscoveryFileReader.existing(markers, in: rootURL)
        guard !files.isEmpty else { return nil }
        let evidence = files.map {
            ProjectDiscoveryParsing.evidence(path: $0.path, detail: "Recognized project marker: \($0.lastPathComponent)")
        }
        return ProjectDiscoveryFinding(
            adapterIdentifier: identifier,
            projectType: "Development workspace",
            evidence: evidence,
            confidence: .stronglyInferred,
            candidates: []
        )
    }
}
