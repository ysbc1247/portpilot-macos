import Foundation

struct ProjectInferer: @unchecked Sendable {
    private let fileManager: FileManager
    private let markerFiles = [
        ".git", "package.json", "pom.xml", "build.gradle", "settings.gradle", "Cargo.toml",
        "go.mod", "pyproject.toml", "docker-compose.yml", "compose.yml"
    ]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func infer(from workingDirectory: String?) -> ProjectInference? {
        guard let workingDirectory, workingDirectory.hasPrefix("/") else { return nil }
        var candidate = URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
        let root = URL(fileURLWithPath: "/", isDirectory: true)

        for _ in 0..<12 {
            if let marker = markerFiles.first(where: {
                fileManager.fileExists(atPath: candidate.appendingPathComponent($0).path)
            }) {
                return ProjectInference(
                    name: packageName(at: candidate) ?? candidate.lastPathComponent,
                    rootPath: candidate.path,
                    evidence: marker
                )
            }
            if candidate == root { break }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        return nil
    }

    private func packageName(at directory: URL) -> String? {
        let url = directory.appendingPathComponent("package.json")
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = object["name"] as? String,
            !name.isEmpty
        else { return nil }
        return name
    }
}
