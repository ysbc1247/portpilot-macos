import Foundation

struct GradleProjectDiscoveryAdapter: ProjectDiscoveryAdapting {
    let identifier = "gradle"

    func discover(in rootURL: URL) throws -> ProjectDiscoveryFinding? {
        guard let buildURL = ProjectDiscoveryFileReader.firstExisting(
            ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
            in: rootURL
        ) else { return nil }
        let text = try ProjectDiscoveryFileReader.text(at: buildURL)
        var tasks = Set(ProjectDiscoveryParsing.captures(
            pattern: #"tasks\.(?:register|create)\s*\(\s*[\"']([A-Za-z0-9:_-]+)[\"']"#,
            text: text
        ))
        tasks.formUnion(ProjectDiscoveryParsing.captures(
            pattern: #"(?m)^\s*task\s+([A-Za-z0-9:_-]+)\b"#,
            text: text
        ))
        if text.contains("org.springframework.boot") || text.contains("bootRun") { tasks.insert("bootRun") }
        if text.contains("application") { tasks.insert("run") }
        let wrapper = rootURL.appendingPathComponent("gradlew")
        let command = FileManager.default.isExecutableFile(atPath: wrapper.path) ? "./gradlew" : "gradle"
        let candidates = tasks.sorted().prefix(50).map { task in
            let evidence = ProjectDiscoveryParsing.evidence(
                path: buildURL.path,
                detail: "Found Gradle task \(task). Task behavior remains untrusted until review."
            )
            return DiscoveredServiceCandidate(
                adapterIdentifier: identifier,
                name: "\(rootURL.lastPathComponent): \(task)",
                launchMechanism: .gradleTask,
                command: command,
                arguments: [task],
                workingDirectory: rootURL.path,
                evidence: [evidence],
                confidence: .stronglyInferred
            )
        }
        return ProjectDiscoveryFinding(
            adapterIdentifier: identifier,
            projectType: "Gradle project",
            evidence: [ProjectDiscoveryParsing.evidence(path: buildURL.path, detail: "Recognized a Gradle build definition.")],
            confidence: .stronglyInferred,
            candidates: candidates
        )
    }
}

struct MavenProjectDiscoveryAdapter: ProjectDiscoveryAdapting {
    let identifier = "maven"

    func discover(in rootURL: URL) throws -> ProjectDiscoveryFinding? {
        let pomURL = rootURL.appendingPathComponent("pom.xml")
        guard FileManager.default.fileExists(atPath: pomURL.path) else { return nil }
        let text = try ProjectDiscoveryFileReader.text(at: pomURL)
        var goals: [String] = []
        if text.contains("spring-boot-maven-plugin") { goals.append("spring-boot:run") }
        if text.contains("quarkus-maven-plugin") { goals.append("quarkus:dev") }
        if text.contains("exec-maven-plugin") { goals.append("exec:java") }
        let wrapper = rootURL.appendingPathComponent("mvnw")
        let command = FileManager.default.isExecutableFile(atPath: wrapper.path) ? "./mvnw" : "mvn"
        let candidates = goals.map { goal in
            let evidence = ProjectDiscoveryParsing.evidence(
                path: pomURL.path,
                detail: "Mapped a declared Maven plugin to the \(goal) goal. Review plugin configuration before use."
            )
            return DiscoveredServiceCandidate(
                adapterIdentifier: identifier,
                name: "\(rootURL.lastPathComponent): \(goal)",
                launchMechanism: .mavenGoal,
                command: command,
                arguments: [goal],
                workingDirectory: rootURL.path,
                evidence: [evidence],
                confidence: .stronglyInferred
            )
        }
        return ProjectDiscoveryFinding(
            adapterIdentifier: identifier,
            projectType: "Maven project",
            evidence: [ProjectDiscoveryParsing.evidence(path: pomURL.path, detail: "Recognized a Maven project model.")],
            confidence: .stronglyInferred,
            candidates: candidates
        )
    }
}

struct PythonProjectDiscoveryAdapter: ProjectDiscoveryAdapting {
    let identifier = "python"

    func discover(in rootURL: URL) throws -> ProjectDiscoveryFinding? {
        let files = ProjectDiscoveryFileReader.existing(
            ["pyproject.toml", "requirements.txt", "manage.py"],
            in: rootURL
        )
        guard !files.isEmpty else { return nil }
        let combined = try files.map { try ProjectDiscoveryFileReader.text(at: $0) }.joined(separator: "\n")
        var candidates: [DiscoveredServiceCandidate] = []
        if let manage = files.first(where: { $0.lastPathComponent == "manage.py" }) {
            candidates.append(candidate(
                rootURL: rootURL,
                name: "Django development server",
                command: "python3",
                arguments: [manage.lastPathComponent, "runserver"],
                evidenceURL: manage,
                detail: "Found Django's manage.py entry point."
            ))
        }
        if combined.localizedCaseInsensitiveContains("flask") {
            candidates.append(candidate(
                rootURL: rootURL,
                name: "Flask development server",
                command: "python3",
                arguments: ["-m", "flask", "run"],
                evidenceURL: files[0],
                detail: "Found a Flask dependency declaration; application selection may still be required."
            ))
        }
        let mainURL = rootURL.appendingPathComponent("main.py")
        if combined.localizedCaseInsensitiveContains("uvicorn"),
           FileManager.default.fileExists(atPath: mainURL.path),
           (try? ProjectDiscoveryFileReader.text(at: mainURL))?.contains("FastAPI(") == true {
            candidates.append(candidate(
                rootURL: rootURL,
                name: "FastAPI development server",
                command: "python3",
                arguments: ["-m", "uvicorn", "main:app", "--reload"],
                evidenceURL: mainURL,
                detail: "Found FastAPI application evidence in main.py and a Uvicorn dependency."
            ))
        }
        if let pyproject = files.first(where: { $0.lastPathComponent == "pyproject.toml" }) {
            let text = try ProjectDiscoveryFileReader.text(at: pyproject)
            for script in projectScripts(in: text).prefix(50) {
                candidates.append(candidate(
                    rootURL: rootURL,
                    name: "Python script: \(script)",
                    command: script,
                    arguments: [],
                    evidenceURL: pyproject,
                    detail: "Found project script \(script). Its referenced function remains untrusted until review."
                ))
            }
        }
        let evidence = files.map {
            ProjectDiscoveryParsing.evidence(path: $0.path, detail: "Recognized Python project metadata: \($0.lastPathComponent)")
        }
        return ProjectDiscoveryFinding(
            adapterIdentifier: identifier,
            projectType: "Python project",
            evidence: evidence,
            confidence: .stronglyInferred,
            candidates: deduplicated(candidates)
        )
    }

    private func candidate(
        rootURL: URL,
        name: String,
        command: String,
        arguments: [String],
        evidenceURL: URL,
        detail: String
    ) -> DiscoveredServiceCandidate {
        DiscoveredServiceCandidate(
            adapterIdentifier: identifier,
            name: "\(rootURL.lastPathComponent): \(name)",
            launchMechanism: .pythonApplication,
            command: command,
            arguments: arguments,
            workingDirectory: rootURL.path,
            evidence: [ProjectDiscoveryParsing.evidence(path: evidenceURL.path, detail: detail)],
            confidence: .stronglyInferred
        )
    }

    private func projectScripts(in text: String) -> [String] {
        var inScripts = false
        var values: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inScripts = line == "[project.scripts]" || line == "[tool.poetry.scripts]"
                continue
            }
            guard inScripts, let separator = line.firstIndex(of: "=") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !name.isEmpty { values.append(name) }
        }
        return values
    }

    private func deduplicated(_ candidates: [DiscoveredServiceCandidate]) -> [DiscoveredServiceCandidate] {
        var names = Set<String>()
        return candidates.filter { names.insert($0.name).inserted }
    }
}

struct GoProjectDiscoveryAdapter: ProjectDiscoveryAdapting {
    let identifier = "go"

    func discover(in rootURL: URL) throws -> ProjectDiscoveryFinding? {
        let url = rootURL.appendingPathComponent("go.mod")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let evidence = ProjectDiscoveryParsing.evidence(path: url.path, detail: "Found a Go module; proposed `go run .` for review.")
        return ProjectDiscoveryFinding(
            adapterIdentifier: identifier,
            projectType: "Go module",
            evidence: [evidence],
            confidence: .stronglyInferred,
            candidates: [DiscoveredServiceCandidate(
                adapterIdentifier: identifier,
                name: "\(rootURL.lastPathComponent): Go application",
                launchMechanism: .goCommand,
                command: "go",
                arguments: ["run", "."],
                workingDirectory: rootURL.path,
                evidence: [evidence],
                confidence: .stronglyInferred
            )]
        )
    }
}

struct CargoProjectDiscoveryAdapter: ProjectDiscoveryAdapting {
    let identifier = "cargo"

    func discover(in rootURL: URL) throws -> ProjectDiscoveryFinding? {
        let url = rootURL.appendingPathComponent("Cargo.toml")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let evidence = ProjectDiscoveryParsing.evidence(path: url.path, detail: "Found a Cargo manifest; proposed `cargo run` for review.")
        return ProjectDiscoveryFinding(
            adapterIdentifier: identifier,
            projectType: "Cargo package",
            evidence: [evidence],
            confidence: .stronglyInferred,
            candidates: [DiscoveredServiceCandidate(
                adapterIdentifier: identifier,
                name: "\(rootURL.lastPathComponent): Cargo application",
                launchMechanism: .cargoCommand,
                command: "cargo",
                arguments: ["run"],
                workingDirectory: rootURL.path,
                evidence: [evidence],
                confidence: .stronglyInferred
            )]
        )
    }
}
