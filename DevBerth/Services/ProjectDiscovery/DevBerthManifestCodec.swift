import Foundation

struct DevBerthManifestCodec: Sendable {
    static let fileName = "devberth-runtime.json"

    func encode(
        projectName: String,
        projectRoot: URL,
        services: [ManagedServiceConfiguration]
    ) throws -> Data {
        let namesByID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0.name) })
        let root = projectRoot.standardizedFileURL.path
        let manifestServices = try services.sorted { $0.name < $1.name }.map { service in
            for name in service.environment.keys where SensitiveEnvironmentKeyPolicy.isSensitive(name) {
                throw DevBerthError.launchValidation(
                    "Environment field \(name) looks secret-like and cannot be exported. Move it to Keychain first."
                )
            }
            return DevBerthManifestService(
                id: service.id,
                name: service.name,
                launchMechanism: service.launchMechanism,
                command: service.command,
                arguments: service.arguments,
                relativeWorkingDirectory: relativePath(service.workingDirectory, root: root),
                shell: service.shell,
                environment: service.environment,
                expectedPorts: service.expectedPorts.map(\.port).sorted(),
                dependencyNames: service.dependencyServiceIDs.compactMap { namesByID[$0] }.sorted(),
                secretNames: service.secretReferences.keys.sorted(),
                startupTimeoutSeconds: service.startupTimeoutSeconds,
                shutdownTimeoutSeconds: service.shutdownTimeoutSeconds,
                restartPolicy: service.restartPolicy
            )
        }
        let manifest = DevBerthProjectManifest(
            schemaVersion: DevBerthProjectManifest.currentSchemaVersion,
            projectName: projectName,
            services: manifestServices
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    func decode(_ data: Data, projectRoot: URL) throws -> DevBerthProjectManifest {
        let manifest: DevBerthProjectManifest
        do {
            manifest = try JSONDecoder().decode(DevBerthProjectManifest.self, from: data)
        } catch {
            throw ProjectDiscoveryError.malformedFile(path: Self.fileName, reason: error.localizedDescription)
        }
        guard manifest.schemaVersion == DevBerthProjectManifest.currentSchemaVersion else {
            throw ProjectDiscoveryError.unsupportedManifestVersion(manifest.schemaVersion)
        }
        return manifest
    }

    func candidates(from manifest: DevBerthProjectManifest, projectRoot: URL) -> [DiscoveredServiceCandidate] {
        let root = projectRoot.standardizedFileURL
        return manifest.services.map { service in
            let workingDirectory = service.relativeWorkingDirectory.hasPrefix("/")
                ? service.relativeWorkingDirectory
                : root.appendingPathComponent(service.relativeWorkingDirectory).standardizedFileURL.path
            let evidence = ProjectDiscoveryParsing.evidence(
                path: root.appendingPathComponent(Self.fileName).path,
                detail: "Imported DevBerth manifest service \(service.name); secrets require local Keychain configuration."
            )
            return DiscoveredServiceCandidate(
                id: service.id,
                adapterIdentifier: "devberth-manifest",
                name: service.name,
                launchMechanism: service.launchMechanism,
                command: service.command,
                arguments: service.arguments,
                workingDirectory: workingDirectory,
                shell: service.shell,
                environment: service.environment,
                expectedPorts: service.expectedPorts,
                dependencyCandidateNames: service.dependencyNames,
                requiredSecretNames: service.secretNames,
                startupTimeoutSeconds: service.startupTimeoutSeconds,
                shutdownTimeoutSeconds: service.shutdownTimeoutSeconds,
                restartPolicy: service.restartPolicy,
                evidence: [evidence],
                confidence: .stronglyInferred,
                requiresShellReview: service.shell != .direct
            )
        }
    }

    private func relativePath(_ path: String, root: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if standardized == root { return "." }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard standardized.hasPrefix(prefix) else { return standardized }
        return String(standardized.dropFirst(prefix.count))
    }
}

struct DevBerthManifestDiscoveryAdapter: ProjectDiscoveryAdapting {
    let identifier = "devberth-manifest"

    func discover(in rootURL: URL) throws -> ProjectDiscoveryFinding? {
        let url = rootURL.appendingPathComponent(DevBerthManifestCodec.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let codec = DevBerthManifestCodec()
        let manifest = try codec.decode(ProjectDiscoveryFileReader.data(at: url), projectRoot: rootURL)
        let candidates = codec.candidates(from: manifest, projectRoot: rootURL)
        let evidence = ProjectDiscoveryParsing.evidence(
            path: url.path,
            detail: "Parsed DevBerth manifest schema \(manifest.schemaVersion) with \(candidates.count) service(s)."
        )
        return ProjectDiscoveryFinding(
            adapterIdentifier: identifier,
            projectType: "DevBerth project manifest",
            evidence: [evidence],
            confidence: .stronglyInferred,
            candidates: candidates
        )
    }
}

actor LocalProjectManifestService: ProjectManifestServing {
    private let codec: DevBerthManifestCodec

    init(codec: DevBerthManifestCodec = DevBerthManifestCodec()) {
        self.codec = codec
    }

    func export(
        projectName: String,
        projectRoot: URL,
        services: [ManagedServiceConfiguration],
        destination: URL
    ) async throws {
        let data = try codec.encode(
            projectName: projectName,
            projectRoot: projectRoot,
            services: services
        )
        try data.write(to: destination, options: .atomic)
    }
}
