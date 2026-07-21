import Foundation

public enum ControlProtocolConstants {
    public static let version = "1"
    public static let toolSchemaVersion = "1"
    public static let maximumFrameBytes = 4 * 1_024 * 1_024
    public static let defaultTimeoutSeconds = 60.0
    public static let operationLifetimeSeconds = 300.0
    public static let changeSetLifetimeSeconds = 300.0
}

public enum ControlActionSource: String, Codable, Sendable, CaseIterable {
    case gui
    case menuBar
    case mcp
    case cli
    case system
    case external
}

public enum ControlErrorCode: String, Codable, Sendable, CaseIterable {
    case invalidArguments = "invalid_arguments"
    case entityNotFound = "entity_not_found"
    case entityChanged = "entity_changed"
    case staleSnapshot = "stale_snapshot"
    case identityMismatch = "identity_mismatch"
    case ownershipChanged = "ownership_changed"
    case operationExpired = "operation_expired"
    case operationAlreadyUsed = "operation_already_used"
    case operationNotApproved = "operation_not_approved"
    case changeSetExpired = "change_set_expired"
    case conflictDetected = "conflict_detected"
    case dependencyCycle = "dependency_cycle"
    case serviceNotVerified = "service_not_verified"
    case missingDependency = "missing_dependency"
    case missingSecretReference = "missing_secret_reference"
    case secretInputRequired = "secret_input_required"
    case hostUnavailable = "host_unavailable"
    case dockerUnavailable = "docker_unavailable"
    case permissionDenied = "permission_denied"
    case timeout
    case resultTooLarge = "result_too_large"
    case unsupportedCapability = "unsupported_capability"
    case developmentModeRequired = "development_mode_required"
    case productionDataProtected = "production_data_protected"
    case internalError = "internal_error"
}

public struct ControlClientIdentity: Codable, Sendable, Equatable {
    public let name: String
    public let version: String
    public let instanceID: UUID
    public let developmentMode: Bool

    public init(name: String, version: String, instanceID: UUID = UUID(), developmentMode: Bool) {
        self.name = name
        self.version = version
        self.instanceID = instanceID
        self.developmentMode = developmentMode
    }
}

public struct ControlHandshake: Codable, Sendable, Equatable {
    public let protocolVersion: String
    public let toolSchemaVersion: String
    public let client: ControlClientIdentity

    public init(client: ControlClientIdentity) {
        protocolVersion = ControlProtocolConstants.version
        toolSchemaVersion = ControlProtocolConstants.toolSchemaVersion
        self.client = client
    }
}

public struct ControlRequest: Codable, Sendable, Equatable {
    public let handshake: ControlHandshake
    public let requestID: String
    public let correlationID: String
    public let toolName: String
    public let arguments: JSONValue
    public let idempotencyKey: String?
    public let deadline: Date
    public let source: ControlActionSource

    public init(
        handshake: ControlHandshake,
        requestID: String = UUID().uuidString,
        correlationID: String = UUID().uuidString,
        toolName: String,
        arguments: JSONValue = .object([:]),
        idempotencyKey: String? = nil,
        timeoutSeconds: Double = ControlProtocolConstants.defaultTimeoutSeconds,
        source: ControlActionSource = .mcp
    ) {
        self.handshake = handshake
        self.requestID = requestID
        self.correlationID = correlationID
        self.toolName = toolName
        self.arguments = arguments
        self.idempotencyKey = idempotencyKey
        deadline = Date().addingTimeInterval(timeoutSeconds)
        self.source = source
    }
}

public struct ControlWarning: Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ControlFailure: Codable, Sendable, Equatable, Error {
    public let code: ControlErrorCode
    public let message: String
    public let recoverySuggestion: String?
    public let details: JSONValue?

    public init(
        code: ControlErrorCode,
        message: String,
        recoverySuggestion: String? = nil,
        details: JSONValue? = nil
    ) {
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.details = details
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case recoverySuggestion = "recovery_suggestion"
        case details
    }
}

public struct ControlResponse: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let requestID: String
    public let snapshotVersion: UInt64
    public let generatedAt: Date
    public let data: JSONValue?
    public let warnings: [ControlWarning]
    public let truncated: Bool
    public let nextCursor: String?
    public let error: ControlFailure?

    public init(
        requestID: String,
        snapshotVersion: UInt64,
        data: JSONValue,
        warnings: [ControlWarning] = [],
        truncated: Bool = false,
        nextCursor: String? = nil
    ) {
        schemaVersion = ControlProtocolConstants.toolSchemaVersion
        self.requestID = requestID
        self.snapshotVersion = snapshotVersion
        generatedAt = Date()
        self.data = data
        self.warnings = warnings
        self.truncated = truncated
        self.nextCursor = nextCursor
        error = nil
    }

    public init(requestID: String, snapshotVersion: UInt64, failure: ControlFailure) {
        schemaVersion = ControlProtocolConstants.toolSchemaVersion
        self.requestID = requestID
        self.snapshotVersion = snapshotVersion
        generatedAt = Date()
        data = nil
        warnings = []
        truncated = false
        nextCursor = nil
        error = failure
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case snapshotVersion = "snapshot_version"
        case generatedAt = "generated_at"
        case data
        case warnings
        case truncated
        case nextCursor = "next_cursor"
        case error
    }
}

public struct ControlHostStatus: Codable, Sendable, Equatable {
    public let product: String
    public let productVersion: String
    public let protocolVersion: String
    public let toolSchemaVersion: String
    public let persistenceSchemaVersion: Int
    public let developmentMode: Bool
    public let connectedClientCount: Int

    public init(
        product: String,
        productVersion: String,
        persistenceSchemaVersion: Int,
        developmentMode: Bool,
        connectedClientCount: Int
    ) {
        self.product = product
        self.productVersion = productVersion
        protocolVersion = ControlProtocolConstants.version
        toolSchemaVersion = ControlProtocolConstants.toolSchemaVersion
        self.persistenceSchemaVersion = persistenceSchemaVersion
        self.developmentMode = developmentMode
        self.connectedClientCount = connectedClientCount
    }
}
