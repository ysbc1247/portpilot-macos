import Foundation

struct ObservedProcessProvider: Sendable {
    private let inspector: any ProcessInspecting
    private let inferer: ProjectInferer?

    init(runner: any CommandRunning, inferer: ProjectInferer? = ProjectInferer()) {
        inspector = SystemProcessInspector(runner: runner)
        self.inferer = inferer
    }

    init(inspector: any ProcessInspecting, inferer: ProjectInferer?) {
        self.inspector = inspector
        self.inferer = inferer
    }

    func metadata(pid: Int32, fallbackName: String, fallbackOwner: String) async -> ObservedProcess {
        let inspection = try? await inspector.inspect(pid: pid)
        let fingerprint = inspection?.fingerprint ?? ProcessFingerprint(
            pid: pid,
            executablePath: nil,
            startTime: nil
        )
        let executable = fingerprint.executablePath
        let currentDirectory = inspection?.currentDirectory
        let commandLine = inspection?.commandLine ?? fallbackName
        let name = executable.map { URL(fileURLWithPath: $0).lastPathComponent } ?? fallbackName
        return ObservedProcess(
            fingerprint: fingerprint,
            name: name,
            commandLine: commandLine,
            owner: fallbackOwner,
            currentDirectory: currentDirectory,
            parentName: nil,
            runtime: ProcessClassifier.classify(name: name, executable: executable, command: commandLine),
            project: inferer?.infer(from: currentDirectory),
            isSystemProcess: SystemProcessClassifier.isSystemProcess(
                name: name,
                executable: executable,
                owner: fallbackOwner,
                currentDirectory: currentDirectory
            ),
            docker: nil,
            launchedByDevBerth: false,
            managedServiceID: nil
        )
    }
}
