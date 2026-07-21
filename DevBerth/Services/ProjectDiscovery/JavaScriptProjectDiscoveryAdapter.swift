import Foundation

struct JavaScriptProjectDiscoveryAdapter: ProjectDiscoveryAdapting {
    let identifier = "javascript-package"

    func discover(in rootURL: URL) throws -> ProjectDiscoveryFinding? {
        let packageURL = rootURL.appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: packageURL.path) else { return nil }
        let data = try ProjectDiscoveryFileReader.data(at: packageURL)
        let object: [String: Any]
        do {
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            throw ProjectDiscoveryError.malformedFile(path: packageURL.path, reason: error.localizedDescription)
        }
        let scripts = object["scripts"] as? [String: String] ?? [:]
        let manager = packageManager(in: object, rootURL: rootURL)
        let projectName = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? rootURL.lastPathComponent
        let projectType = detectedProjectType(object: object, rootURL: rootURL)
        let baseEvidence = ProjectDiscoveryParsing.evidence(
            path: packageURL.path,
            detail: "Parsed \(scripts.count) package script(s) for \(manager.title)."
        )
        let candidates = scripts.keys.sorted().prefix(100).compactMap { scriptName -> DiscoveredServiceCandidate? in
            guard let script = scripts[scriptName], !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let evidence = ProjectDiscoveryParsing.evidence(
                path: packageURL.path,
                detail: "Found package script named \(scriptName). Its body remains untrusted until review."
            )
            return DiscoveredServiceCandidate(
                adapterIdentifier: identifier,
                name: "\(projectName): \(scriptName)",
                launchMechanism: manager.mechanism,
                command: manager.command,
                arguments: manager.arguments(for: scriptName),
                workingDirectory: rootURL.path,
                expectedPorts: ProjectDiscoveryParsing.inferredPorts(in: script),
                evidence: [evidence],
                confidence: .stronglyInferred
            )
        }
        return ProjectDiscoveryFinding(
            adapterIdentifier: identifier,
            projectType: projectType,
            evidence: [baseEvidence],
            confidence: .stronglyInferred,
            candidates: candidates
        )
    }

    private func packageManager(in object: [String: Any], rootURL: URL) -> JavaScriptPackageManager {
        if let declared = object["packageManager"] as? String {
            if declared.hasPrefix("pnpm@") { return .pnpm }
            if declared.hasPrefix("yarn@") { return .yarn }
            if declared.hasPrefix("bun@") { return .bun }
            if declared.hasPrefix("npm@") { return .npm }
        }
        if ProjectDiscoveryFileReader.firstExisting(["pnpm-lock.yaml"], in: rootURL) != nil { return .pnpm }
        if ProjectDiscoveryFileReader.firstExisting(["yarn.lock"], in: rootURL) != nil { return .yarn }
        if ProjectDiscoveryFileReader.firstExisting(["bun.lock", "bun.lockb"], in: rootURL) != nil { return .bun }
        return .npm
    }

    private func detectedProjectType(object: [String: Any], rootURL: URL) -> String {
        let dependencies = (object["dependencies"] as? [String: Any] ?? [:])
            .merging(object["devDependencies"] as? [String: Any] ?? [:]) { current, _ in current }
        if dependencies["next"] != nil || ProjectDiscoveryFileReader.firstExisting(["next.config.js", "next.config.mjs", "next.config.ts"], in: rootURL) != nil {
            return "Next.js"
        }
        if dependencies["vite"] != nil || ProjectDiscoveryFileReader.firstExisting(["vite.config.js", "vite.config.ts", "vite.config.mjs"], in: rootURL) != nil {
            return "Vite"
        }
        if ProjectDiscoveryFileReader.firstExisting(["nx.json"], in: rootURL) != nil { return "Nx workspace" }
        if ProjectDiscoveryFileReader.firstExisting(["turbo.json"], in: rootURL) != nil { return "Turborepo" }
        return "JavaScript package"
    }
}

private enum JavaScriptPackageManager {
    case npm
    case pnpm
    case yarn
    case bun

    var title: String {
        switch self {
        case .npm: "npm"
        case .pnpm: "pnpm"
        case .yarn: "Yarn"
        case .bun: "Bun"
        }
    }

    var command: String { title.lowercased() }

    var mechanism: LaunchMechanism {
        switch self {
        case .npm: .npmScript
        case .pnpm: .pnpmScript
        case .yarn: .yarnScript
        case .bun: .bunScript
        }
    }

    func arguments(for script: String) -> [String] {
        switch self {
        case .npm, .pnpm, .bun: ["run", script]
        case .yarn: [script]
        }
    }
}
