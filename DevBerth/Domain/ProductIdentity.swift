import Foundation

enum ProductIdentity {
    static let currentName = "DevBerth"
    static let legacyName = "PortPilot"

    static let currentBundleIdentifier = "com.ysbc.devberth"
    static let legacyBundleIdentifier = "com.ysbc.portpilot"

    static let currentStoreFilename = "DevBerth.store"
    static let legacyStoreFilename = "PortPilot.store"

    static let currentSupportDirectoryName = "DevBerth"
    static let legacySupportDirectoryName = "PortPilot"

    static let currentKeychainService = "com.ysbc.devberth.secrets"
    static let legacyKeychainService = "com.ysbc.portpilot.secrets"

    static let defaultsMigrationMarker = "DevBerth.productIdentityMigrationVersion"
    static let defaultsMigrationVersion = 1

    static let knownNonSecretDefaultKeys: Set<String> = [
        "refreshInterval",
        "historyRetentionDays",
        "notifyConfiguredPorts",
        "activePorts.columnCustomization",
        "NSWindow Frame main-AppWindow-1",
        "NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView"
    ]
}
