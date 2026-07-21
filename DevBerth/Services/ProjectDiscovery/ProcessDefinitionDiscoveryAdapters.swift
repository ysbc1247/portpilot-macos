import Foundation

struct DockerComposeProjectDiscoveryAdapter: ProjectDiscoveryAdapting {
    let identifier = "docker-compose"

    func discover(in rootURL: URL) throws -> ProjectDiscoveryFinding? {
        guard let fileURL = ProjectDiscoveryFileReader.firstExisting(
            ["compose.yml", "compose.yaml", "docker-compose.yml", "docker-compose.yaml"],
            in: rootURL
        ) else { return nil }
        let text = try ProjectDiscoveryFileReader.text(at: fileURL)
        let definitions = SimpleYAMLProcessParser.processes(in: text, rootKey: "services")
        let candidates = definitions.map { definition in
            let evidence = ProjectDiscoveryParsing.evidence(
                path: fileURL.path,
                detail: "Found Compose service \(definition.name) in the selected configuration file."
            )
            return DiscoveredServiceCandidate(
                adapterIdentifier: identifier,
                name: "\(rootURL.lastPathComponent): \(definition.name)",
                launchMechanism: .dockerComposeService,
                command: "docker",
                arguments: ["compose", "-f", fileURL.path, "up", definition.name],
                workingDirectory: rootURL.path,
                expectedPorts: definition.ports,
                dependencyCandidateNames: definition.dependencies.map { "\(rootURL.lastPathComponent): \($0)" },
                evidence: [evidence],
                confidence: .stronglyInferred
            )
        }
        let evidence = ProjectDiscoveryParsing.evidence(
            path: fileURL.path,
            detail: "Parsed \(definitions.count) Compose service definition(s) without executing Docker."
        )
        return ProjectDiscoveryFinding(
            adapterIdentifier: identifier,
            projectType: "Docker Compose project",
            evidence: [evidence],
            confidence: .stronglyInferred,
            candidates: candidates
        )
    }
}

struct ProcfileProjectDiscoveryAdapter: ProjectDiscoveryAdapting {
    let identifier = "procfile"

    func discover(in rootURL: URL) throws -> ProjectDiscoveryFinding? {
        let fileURL = rootURL.appendingPathComponent("Procfile")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let text = try ProjectDiscoveryFileReader.text(at: fileURL)
        let candidates = text.split(whereSeparator: \.isNewline).compactMap { rawLine -> DiscoveredServiceCandidate? in
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: ":") else {
                return nil
            }
            let name = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let commandStart = trimmed.index(after: separator)
            let command = trimmed[commandStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !command.isEmpty else { return nil }
            let evidence = ProjectDiscoveryParsing.evidence(
                path: fileURL.path,
                detail: "Found Procfile process \(name). Its shell expression is untrusted until line-by-line review."
            )
            return DiscoveredServiceCandidate(
                adapterIdentifier: identifier,
                name: "\(rootURL.lastPathComponent): \(name)",
                launchMechanism: .procfileProcess,
                command: command,
                workingDirectory: rootURL.path,
                shell: .custom(path: "/bin/zsh"),
                expectedPorts: ProjectDiscoveryParsing.inferredPorts(in: command),
                evidence: [evidence],
                confidence: .stronglyInferred,
                requiresShellReview: true
            )
        }
        return ProjectDiscoveryFinding(
            adapterIdentifier: identifier,
            projectType: "Procfile application",
            evidence: [ProjectDiscoveryParsing.evidence(path: fileURL.path, detail: "Parsed \(candidates.count) Procfile process definition(s).")],
            confidence: .stronglyInferred,
            candidates: candidates
        )
    }
}

struct ProcessComposeProjectDiscoveryAdapter: ProjectDiscoveryAdapting {
    let identifier = "process-compose"

    func discover(in rootURL: URL) throws -> ProjectDiscoveryFinding? {
        guard let fileURL = ProjectDiscoveryFileReader.firstExisting(
            ["process-compose.yaml", "process-compose.yml"],
            in: rootURL
        ) else { return nil }
        let text = try ProjectDiscoveryFileReader.text(at: fileURL)
        let definitions = SimpleYAMLProcessParser.processes(in: text, rootKey: "processes")
        let candidates = definitions.compactMap { definition -> DiscoveredServiceCandidate? in
            guard let command = definition.command, !command.isEmpty else { return nil }
            let evidence = ProjectDiscoveryParsing.evidence(
                path: fileURL.path,
                detail: "Found Process Compose process \(definition.name). Its shell expression is untrusted until review."
            )
            return DiscoveredServiceCandidate(
                adapterIdentifier: identifier,
                name: "\(rootURL.lastPathComponent): \(definition.name)",
                launchMechanism: .processComposeService,
                command: command,
                workingDirectory: rootURL.path,
                shell: .custom(path: "/bin/zsh"),
                expectedPorts: definition.ports + ProjectDiscoveryParsing.inferredPorts(in: command),
                dependencyCandidateNames: definition.dependencies.map { "\(rootURL.lastPathComponent): \($0)" },
                evidence: [evidence],
                confidence: .stronglyInferred,
                requiresShellReview: true
            )
        }
        return ProjectDiscoveryFinding(
            adapterIdentifier: identifier,
            projectType: "Process Compose project",
            evidence: [ProjectDiscoveryParsing.evidence(path: fileURL.path, detail: "Parsed \(definitions.count) Process Compose process definition(s).")],
            confidence: .stronglyInferred,
            candidates: candidates
        )
    }
}

private struct SimpleYAMLProcessDefinition {
    let name: String
    var dependencies: [String]
    var ports: [UInt16]
    var command: String?
}

private enum SimpleYAMLProcessParser {
    static func processes(in text: String, rootKey: String) -> [SimpleYAMLProcessDefinition] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard let rootIndex = lines.firstIndex(where: {
            normalizedContent($0) == "\(rootKey):"
        }) else { return [] }
        let rootIndent = indentation(lines[rootIndex])
        var serviceIndent: Int?
        var currentName: String?
        var currentProperty: (name: String, indent: Int)?
        var propertyItemIndent: Int?
        var definitions: [String: SimpleYAMLProcessDefinition] = [:]
        var order: [String] = []

        for line in lines.dropFirst(rootIndex + 1) {
            let content = normalizedContent(line)
            guard !content.isEmpty, !content.hasPrefix("#") else { continue }
            let indent = indentation(line)
            if indent <= rootIndent { break }
            if serviceIndent == nil, content.hasSuffix(":"), !content.hasPrefix("-") {
                serviceIndent = indent
            }
            if indent == serviceIndent, content.hasSuffix(":"), !content.hasPrefix("-") {
                let name = unquoted(String(content.dropLast())).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                currentName = name
                currentProperty = nil
                propertyItemIndent = nil
                if definitions[name] == nil {
                    definitions[name] = SimpleYAMLProcessDefinition(name: name, dependencies: [], ports: [], command: nil)
                    order.append(name)
                }
                continue
            }
            guard let currentName, indent > (serviceIndent ?? rootIndent) else { continue }
            if content.hasPrefix("depends_on:") {
                currentProperty = ("depends_on", indent)
                propertyItemIndent = nil
                let inline = inlineList(after: "depends_on:", in: content)
                definitions[currentName]?.dependencies.append(contentsOf: inline)
                continue
            }
            if content.hasPrefix("ports:") {
                currentProperty = ("ports", indent)
                propertyItemIndent = nil
                continue
            }
            if content.hasPrefix("command:") {
                let value = String(content.dropFirst("command:".count)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { definitions[currentName]?.command = unquoted(value) }
                currentProperty = ("command", indent)
                propertyItemIndent = nil
                continue
            }
            guard let property = currentProperty, indent > property.indent else {
                currentProperty = nil
                propertyItemIndent = nil
                continue
            }
            if propertyItemIndent == nil { propertyItemIndent = indent }
            guard indent == propertyItemIndent else { continue }
            switch property.name {
            case "depends_on":
                let value = content.hasPrefix("-")
                    ? String(content.dropFirst()).trimmingCharacters(in: .whitespaces)
                    : String(content.split(separator: ":", maxSplits: 1).first ?? "")
                let dependency = unquoted(value)
                if !dependency.isEmpty { definitions[currentName]?.dependencies.append(dependency) }
            case "ports":
                definitions[currentName]?.ports.append(contentsOf: ProjectDiscoveryParsing.composeHostPorts(in: content))
            case "command":
                if definitions[currentName]?.command == nil {
                    let value = content.hasPrefix("-")
                        ? String(content.dropFirst()).trimmingCharacters(in: .whitespaces)
                        : content
                    definitions[currentName]?.command = unquoted(value)
                }
            default:
                break
            }
        }
        return order.compactMap { name in
            guard var definition = definitions[name] else { return nil }
            definition.dependencies = Array(Set(definition.dependencies)).sorted()
            definition.ports = Array(Set(definition.ports)).sorted()
            return definition
        }
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func normalizedContent(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    private static func unquoted(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func inlineList(after key: String, in content: String) -> [String] {
        let value = content.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("["), value.hasSuffix("]") else { return [] }
        return value.dropFirst().dropLast().split(separator: ",")
            .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }
}
