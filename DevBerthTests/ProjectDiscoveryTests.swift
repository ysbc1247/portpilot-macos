import SwiftData
import XCTest
@testable import DevBerth

final class ProjectDiscoveryTests: XCTestCase {
    func testJavaScriptAdapterUsesDeclaredPackageManagerAndKeepsScriptUnreviewed() throws {
        for (manager, expectedCommand, expectedMechanism, expectedArguments) in [
            ("npm@10.0.0", "npm", LaunchMechanism.npmScript, ["run", "dev"]),
            ("pnpm@9.0.0", "pnpm", .pnpmScript, ["run", "dev"]),
            ("yarn@4.0.0", "yarn", .yarnScript, ["dev"]),
            ("bun@1.1.0", "bun", .bunScript, ["run", "dev"])
        ] {
            try withProject { root in
                try write(
                    """
                    {"name":"web","packageManager":"\(manager)","scripts":{"dev":"vite --port 4310"},"devDependencies":{"vite":"1"}}
                    """,
                    named: "package.json",
                    in: root
                )
                let finding = try XCTUnwrap(JavaScriptProjectDiscoveryAdapter().discover(in: root))
                let candidate = try XCTUnwrap(finding.candidates.first)
                XCTAssertEqual(finding.projectType, "Vite")
                XCTAssertEqual(candidate.command, expectedCommand)
                XCTAssertEqual(candidate.launchMechanism, expectedMechanism)
                XCTAssertEqual(candidate.arguments, expectedArguments)
                XCTAssertEqual(candidate.expectedPorts, [4310])
                XCTAssertFalse(candidate.unreviewedConfiguration(projectID: nil).isReviewed)
            }
        }
    }

    func testCoordinatorRecognizesRequiredNativeEcosystemsWithoutRecursing() throws {
        try withProject { root in
            try write("plugins { id 'org.springframework.boot' }\ntasks.register(\"serve\")", named: "build.gradle", in: root)
            try write("<plugin><artifactId>spring-boot-maven-plugin</artifactId></plugin>", named: "pom.xml", in: root)
            try write("[project]\ndependencies = [\"flask\"]", named: "pyproject.toml", in: root)
            try write("module example.test/app", named: "go.mod", in: root)
            try write("[package]\nname = \"fixture\"", named: "Cargo.toml", in: root)
            let nested = root.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try write("{\"scripts\":{\"nested\":\"node nested.js\"}}", named: "package.json", in: nested)

            let report = try ProjectDiscoveryCoordinator().discover(at: root)
            let mechanisms = Set(report.candidates.map(\.launchMechanism))
            XCTAssertTrue(mechanisms.isSuperset(of: [.gradleTask, .mavenGoal, .pythonApplication, .goCommand, .cargoCommand]))
            XCTAssertFalse(report.candidates.contains { $0.name.contains("nested") })
        }
    }

    func testComposeAdapterPreservesExactFilePortsAndDependencies() throws {
        try withProject { root in
            try write(
                """
                services:
                  db:
                    image: postgres:17
                    ports:
                      - "5544:5432"
                  api:
                    image: api
                    depends_on:
                      db:
                        condition: service_healthy
                    ports:
                      - '8088:8080'
                """,
                named: "compose.yaml",
                in: root
            )
            let finding = try XCTUnwrap(DockerComposeProjectDiscoveryAdapter().discover(in: root))
            let api = try XCTUnwrap(finding.candidates.first { $0.name.hasSuffix(": api") })
            XCTAssertEqual(api.expectedPorts, [8088])
            XCTAssertEqual(api.dependencyCandidateNames, ["\(root.lastPathComponent): db"])
            XCTAssertEqual(api.arguments, ["compose", "-f", root.appendingPathComponent("compose.yaml").path, "up", "api"])
        }
    }

    func testProcfileAndProcessComposeCommandsRequireShellReview() throws {
        try withProject { root in
            try write("web: bundle exec puma -p 9292\nworker: bundle exec sidekiq", named: "Procfile", in: root)
            try write(
                """
                processes:
                  api:
                    command: python3 -m uvicorn main:app --port 8444
                    depends_on: [db]
                """,
                named: "process-compose.yaml",
                in: root
            )
            let report = try ProjectDiscoveryCoordinator().discover(at: root)
            let shellCandidates = report.candidates.filter {
                $0.launchMechanism == .procfileProcess || $0.launchMechanism == .processComposeService
            }
            XCTAssertEqual(shellCandidates.count, 3)
            XCTAssertTrue(shellCandidates.allSatisfy(\.requiresShellReview))
            XCTAssertTrue(shellCandidates.allSatisfy { $0.shell == .custom(path: "/bin/zsh") })
            XCTAssertEqual(
                shellCandidates.first { $0.launchMechanism == .processComposeService }?.expectedPorts,
                [8444]
            )
        }
    }

    func testManifestRoundTripUsesRelativePathsAndOmitsSecretReferences() throws {
        try withProject { root in
            let database = ManagedServiceConfiguration(
                name: "Database",
                command: "postgres",
                workingDirectory: root.path,
                secretReferences: ["DATABASE_PASSWORD": UUID()],
                expectedPorts: [.init(id: UUID(), port: 5432, protocolKind: .tcp, required: true)]
            )
            let apiFolder = root.appendingPathComponent("api", isDirectory: true)
            try FileManager.default.createDirectory(at: apiFolder, withIntermediateDirectories: true)
            let api = ManagedServiceConfiguration(
                name: "API",
                command: "go",
                arguments: ["run", "."],
                workingDirectory: apiFolder.path,
                environment: ["LOG_LEVEL": "debug"],
                expectedPorts: [.init(id: UUID(), port: 8080, protocolKind: .tcp, required: true)],
                dependencyServiceIDs: [database.id]
            )
            let codec = DevBerthManifestCodec()
            let data = try codec.encode(projectName: "Fixture", projectRoot: root, services: [api, database])
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains(database.secretReferences.values.first?.uuidString ?? "missing"))
            let manifest = try codec.decode(data, projectRoot: root)
            let apiManifest = try XCTUnwrap(manifest.services.first { $0.name == "API" })
            XCTAssertEqual(apiManifest.relativeWorkingDirectory, "api")
            XCTAssertEqual(apiManifest.dependencyNames, ["Database"])
            XCTAssertEqual(manifest.services.first { $0.name == "Database" }?.secretNames, ["DATABASE_PASSWORD"])
            let candidates = codec.candidates(from: manifest, projectRoot: root)
            XCTAssertEqual(candidates.count, 2)
            XCTAssertEqual(candidates.first { $0.name == "API" }?.environment, ["LOG_LEVEL": "debug"])
            XCTAssertEqual(candidates.first { $0.name == "Database" }?.requiredSecretNames, ["DATABASE_PASSWORD"])
            let importedDatabase = try XCTUnwrap(candidates.first { $0.name == "Database" })
            XCTAssertEqual(
                Set(importedDatabase.unreviewedConfiguration(projectID: nil).secretReferences.keys),
                Set(["DATABASE_PASSWORD"])
            )
        }
    }

    func testManifestExportRejectsSecretLikePlainEnvironment() throws {
        try withProject { root in
            let service = ManagedServiceConfiguration(
                name: "Unsafe",
                command: "true",
                workingDirectory: root.path,
                environment: ["API_TOKEN": "not-for-export"]
            )
            XCTAssertThrowsError(try DevBerthManifestCodec().encode(
                projectName: "Unsafe",
                projectRoot: root,
                services: [service]
            ))
        }
    }

    @MainActor
    func testImporterPersistsUnreviewedProfilesDependenciesAndDiscoveryEvidence() throws {
        let schema = Schema(DevBerthSchemaV6.models)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DevBerthMigrationPlan.self,
            configurations: [ModelConfiguration("DiscoveryImport", schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let projectID = UUID()
        let root = "/tmp/discovery-import"
        let database = DiscoveredServiceCandidate(
            adapterIdentifier: "fixture",
            name: "Database",
            launchMechanism: .genericCommand,
            command: "postgres",
            workingDirectory: root,
            expectedPorts: [5432],
            evidence: [.init(path: "fixture", detail: "database", confidence: .stronglyInferred)],
            confidence: .stronglyInferred
        )
        let api = DiscoveredServiceCandidate(
            adapterIdentifier: "fixture",
            name: "API",
            launchMechanism: .goCommand,
            command: "go",
            arguments: ["run", "."],
            workingDirectory: root,
            expectedPorts: [8080],
            dependencyCandidateNames: ["Database"],
            evidence: [.init(path: "fixture", detail: "api", confidence: .stronglyInferred)],
            confidence: .stronglyInferred
        )
        let finding = ProjectDiscoveryFinding(
            adapterIdentifier: "fixture",
            projectType: "Fixture",
            evidence: [.init(path: "fixture", detail: "root", confidence: .stronglyInferred)],
            confidence: .stronglyInferred,
            candidates: [database, api]
        )
        let report = ProjectDiscoveryReport(rootPath: root, findings: [finding], discoveredAt: Date())

        let result = try ProjectDiscoveryImporter.importCandidates(
            [database, api],
            report: report,
            projectID: projectID,
            into: context
        )

        XCTAssertEqual(Set(result.importedServiceIDs), Set([database.id, api.id]))
        XCTAssertTrue(result.unresolvedDependencies.isEmpty)
        let profiles = try context.fetch(FetchDescriptor<LaunchProfileRecord>())
        XCTAssertEqual(profiles.count, 2)
        XCTAssertTrue(profiles.allSatisfy { !$0.isReviewed && $0.projectID == projectID })
        let dependency = try XCTUnwrap(context.fetch(FetchDescriptor<ProfileDependencyRecord>()).first)
        XCTAssertEqual(dependency.profileID, api.id)
        XCTAssertEqual(dependency.dependencyProfileID, database.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ProjectDiscoveryRecord>()).count, 1)
    }

    private func withProject(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevBerthDiscovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ text: String, named name: String, in root: URL) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name), options: .atomic)
    }
}
