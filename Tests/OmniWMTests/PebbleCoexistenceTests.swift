// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class PebbleCoexistenceTests: XCTestCase {
    func testDefaultSocketIsSeparateFromOfficialAppAndOverrideIsRespected() {
        let path = IPCSocketPath.resolvedPath(environment: [:])
        XCTAssertTrue(path.hasSuffix("/com.jadewisemann.OmniWM.Pebble/ipc.sock"))
        XCTAssertEqual(
            IPCSocketPath.resolvedPath(environment: ["OMNIWM_SOCKET": "/tmp/custom-pebble.sock"]),
            "/tmp/custom-pebble.sock"
        )
    }

    func testInstallingPebbleCLIPreservesOfficialCLI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        let app = root.appendingPathComponent("OmniWM Pebble.app")
        let bundledCLI = app.appendingPathComponent("Contents/MacOS/omniwmctl")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bundledCLI.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundledCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledCLI.path)
        let officialCLI = bin.appendingPathComponent("omniwmctl")
        try Data("official CLI".utf8).write(to: officialCLI)

        let manager = AppCLIManager(
            environmentProvider: { ["PATH": bin.path] },
            bundleURLProvider: { app },
            homeDirectoryURLProvider: { root },
            homebrewLinkURLsProvider: { [] }
        )
        let result = try manager.installCLIToPATH()
        XCTAssertEqual(
            result,
            .installed(linkURL: bin.appendingPathComponent("omniwm-pebblectl"), directoryOnPath: true)
        )
        XCTAssertEqual(try String(contentsOf: officialCLI, encoding: .utf8), "official CLI")
        _ = try manager.removeInstalledCLI()
        XCTAssertEqual(try String(contentsOf: officialCLI, encoding: .utf8), "official CLI")
    }
}
