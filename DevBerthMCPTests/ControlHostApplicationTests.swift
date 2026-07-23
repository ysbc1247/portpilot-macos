import DevBerthControlContracts
import Foundation
import XCTest

final class ControlHostApplicationTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devberth-control-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testDevelopmentResolutionRequiresExplicitPath() {
        XCTAssertThrowsError(try ControlHostApplication.resolveDevelopment(environment: [:])) { error in
            XCTAssertEqual(error as? ControlHostApplicationError, .missingDevelopmentApplicationPath)
        }
    }

    func testDevelopmentResolutionAcceptsExactMarkedDebugBundle() throws {
        let bundle = try makeBundle(developmentAllowed: true)
        let identity = try ControlHostApplication.resolveDevelopment(environment: [
            ControlHostApplication.developmentPathEnvironmentKey: bundle.path
        ])

        XCTAssertEqual(identity.bundleURL, bundle.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(identity.executableURL, bundle.appendingPathComponent("Contents/MacOS/DevBerth"))
    }

    func testDevelopmentResolutionRejectsReleaseBundleWithSharedIdentity() throws {
        let bundle = try makeBundle(developmentAllowed: false)

        XCTAssertThrowsError(try ControlHostApplication.resolveDevelopment(environment: [
            ControlHostApplication.developmentPathEnvironmentKey: bundle.path
        ])) { error in
            XCTAssertEqual(error as? ControlHostApplicationError, .developmentBundleRequired)
        }
    }

    func testDevelopmentResolutionRejectsWrongBundleIdentifier() throws {
        let bundle = try makeBundle(
            developmentAllowed: true,
            bundleIdentifier: "com.example.lookalike"
        )

        XCTAssertThrowsError(try ControlHostApplication.resolveDevelopment(environment: [
            ControlHostApplication.developmentPathEnvironmentKey: bundle.path
        ])) { error in
            guard let applicationError = error as? ControlHostApplicationError,
                  case let .invalidBundle(reason) = applicationError else {
                return XCTFail("Expected invalid bundle error, got \(error)")
            }
            XCTAssertTrue(reason.contains(ControlHostApplication.bundleIdentifier))
        }
    }

    func testProductionValidationRejectsDevelopmentBundle() throws {
        let bundle = try makeBundle(developmentAllowed: true)

        XCTAssertThrowsError(try ControlHostApplication.validate(
            bundleURL: bundle,
            requiresDevelopmentPermission: false
        )) { error in
            XCTAssertEqual(error as? ControlHostApplicationError, .productionBundleRequired)
        }
    }

    func testValidationRejectsMissingExecutable() throws {
        let bundle = try makeBundle(developmentAllowed: true, createExecutable: false)

        XCTAssertThrowsError(try ControlHostApplication.resolveDevelopment(environment: [
            ControlHostApplication.developmentPathEnvironmentKey: bundle.path
        ])) { error in
            guard let applicationError = error as? ControlHostApplicationError,
                  case let .invalidBundle(reason) = applicationError else {
                return XCTFail("Expected invalid bundle error, got \(error)")
            }
            XCTAssertTrue(reason.contains("missing or not executable"))
        }
    }

    private func makeBundle(
        developmentAllowed: Bool,
        bundleIdentifier: String = ControlHostApplication.bundleIdentifier,
        createExecutable: Bool = true
    ) throws -> URL {
        let bundle = temporaryDirectory.appendingPathComponent("DevBerth.app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": ControlHostApplication.executableName,
            ControlHostApplication.developmentAllowedInfoKey: developmentAllowed ? "YES" : "NO"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)

        if createExecutable {
            let executable = macOS.appendingPathComponent(ControlHostApplication.executableName)
            XCTAssertTrue(FileManager.default.createFile(
                atPath: executable.path,
                contents: Data("#!/bin/sh\n".utf8),
                attributes: [.posixPermissions: NSNumber(value: 0o755)]
            ))
        }
        return bundle
    }
}
