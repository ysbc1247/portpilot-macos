import SwiftData
import SwiftUI
import DevBerthControlContracts

@main
@MainActor
struct DevBerthApp: App {
    @StateObject private var model: AppModel
    @StateObject private var controlHostStatus: ControlHostStatusModel
    private let container: ModelContainer
    private let controlHost: DevBerthControlHost?

    init() {
        do {
            let schema = Schema(DevBerthSchemaV7.models)
            let isUITesting = ProcessInfo.processInfo.environment["DEVBERTH_UI_TESTING"] == "1"
            let isHostedTesting = ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
#if DEBUG
            let isDevelopmentHost = ProcessInfo.processInfo.arguments.contains("--development-control-host")
                && ProcessInfo.processInfo.environment["DEVBERTH_DEVELOPMENT_CONTROL"] == "1"
#else
            let isDevelopmentHost = false
#endif
            let configuration: ModelConfiguration
            if isUITesting || isHostedTesting || isDevelopmentHost {
                configuration = ModelConfiguration(
                    isUITesting ? "DevBerthUITests" : (isHostedTesting ? "DevBerthHostedTests" : "DevBerthDevelopmentControl"),
                    schema: schema, isStoredInMemoryOnly: true
                )
            } else {
                let migration = try ProductDataMigrator().migrateForCurrentUser()
                configuration = ModelConfiguration("DevBerth", schema: schema, url: migration.storeURL)
            }
            let createdContainer = try ModelContainer(
                for: schema,
                migrationPlan: DevBerthMigrationPlan.self,
                configurations: [configuration]
            )
            container = createdContainer
            let store = SwiftDataStore(modelContainer: createdContainer)
#if DEBUG
            let developmentFixtures = isDevelopmentHost ? DevelopmentFixtureController() : nil
            let developmentRuntimeRegistry = isDevelopmentHost ? ManagedRuntimeRegistry() : nil
            let developmentDiscoverer: (any PortDiscovering)? = developmentFixtures.flatMap { fixtures in
                developmentRuntimeRegistry.map { DevelopmentScopedPortDiscoverer(fixtures: fixtures, runtimeRegistry: $0) }
            }
#else
            let developmentFixtures: DevelopmentFixtureController? = nil
            let developmentRuntimeRegistry: ManagedRuntimeRegistry? = nil
            let developmentDiscoverer: (any PortDiscovering)? = nil
#endif
            let discoverer: (any PortDiscovering)?
            if isUITesting {
                discoverer = UITestPortDiscoverer()
            } else if isHostedTesting {
                discoverer = EmptyPortDiscoverer()
            } else {
                discoverer = developmentDiscoverer
            }
            let resourceReader: (any ProcessResourceUsageReading)? = isUITesting || isHostedTesting || isDevelopmentHost
                ? UITestResourceReader()
                : nil
            let createdModel = AppModel(
                discoverer: discoverer,
                historyRecorder: store,
                ownershipRecorder: store,
                restartTrustStore: store,
                workspaceSessionRecorder: store,
                processResourceReader: resourceReader,
                runtimeRegistry: developmentRuntimeRegistry
            )
            _model = StateObject(wrappedValue: createdModel)
            let socketURL = ControlSocketPath.socketURL(developmentMode: isDevelopmentHost)
            let status = ControlHostStatusModel(socketURL: socketURL, developmentMode: isDevelopmentHost)
            _controlHostStatus = StateObject(wrappedValue: status)
            if isUITesting || isHostedTesting {
                status.markDisabled("Tests never expose a control socket.")
                controlHost = nil
            } else {
                let host = DevBerthControlHost(
                    model: createdModel,
                    container: createdContainer,
                    developmentMode: isDevelopmentHost,
                    status: status,
                    fixtureController: developmentFixtures ?? DevelopmentFixtureController()
                )
                controlHost = host
                host.start()
            }
        } catch {
            fatalError("Unable to initialize DevBerth's local database: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup("DevBerth", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(controlHostStatus)
                .frame(minWidth: 980, minHeight: 620)
                .task { model.startMonitoring() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { DevBerthCommands(model: model) }
        .modelContainer(container)

        MenuBarExtra("DevBerth", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuBarView()
                .environmentObject(model)
                .modelContainer(container)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(controlHostStatus)
                .modelContainer(container)
        }
    }
}

private struct EmptyPortDiscoverer: PortDiscovering {
    func discover() async throws -> [ObservedListener] { [] }
}

private struct UITestPortDiscoverer: PortDiscovering {
    func discover() async throws -> [ObservedListener] {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let command = "/usr/bin/python3 -m http.server 45123"
        let process = ObservedProcess(
            fingerprint: ProcessFingerprint(
                pid: 42_424,
                uid: 501,
                executablePath: "/usr/bin/python3",
                startTime: observedAt,
                commandLineDigest: ProcessFingerprint.digest(commandLine: command),
                parentPID: 1,
                detectedAt: observedAt
            ),
            name: "devberth-ui-fixture",
            commandLine: command,
            owner: "ui-test",
            currentDirectory: "/tmp/devberth-ui-fixture",
            parentName: "xctest",
            runtime: .python,
            project: nil,
            isSystemProcess: false,
            docker: nil,
            launchedByDevBerth: false,
            managedServiceID: nil
        )
        return [ObservedListener(
            protocolKind: .tcp,
            address: "127.0.0.1",
            port: 45_123,
            process: process,
            firstDetectedAt: observedAt,
            lastDetectedAt: observedAt
        )]
    }
}

private struct UITestResourceReader: ProcessResourceUsageReading {
    func read(pids: Set<Int32>) async throws -> [Int32: ProcessResourceUsage] {
        Dictionary(uniqueKeysWithValues: pids.map {
            ($0, ProcessResourceUsage(cpuPercent: 1.5, residentMemoryBytes: 12_582_912, capturedAt: Date()))
        })
    }
}

struct DevBerthCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("DevBerth") {
            Button("Refresh Listeners") { model.refreshNow() }
                .keyboardShortcut("r", modifiers: .command)
            Button(model.isMonitoring ? "Pause Monitoring" : "Resume Monitoring") {
                model.isMonitoring ? model.pauseMonitoring() : model.startMonitoring()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}
