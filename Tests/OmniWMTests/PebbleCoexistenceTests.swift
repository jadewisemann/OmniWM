// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import TOML
import XCTest

final class PebbleCoexistenceTests: XCTestCase {
    func testSharedSettingsKeepOfficialSchemaAndPreservePebbleHotkeyAcrossOfficialSave() throws {
        var export = SettingsExport.defaults()
        let moveIndex = try XCTUnwrap(export.hotkeyBindings.firstIndex { $0.id == "moveWindowToMonitor.next" })
        export.hotkeyBindings[moveIndex].binding = .unassigned
        let data = try SettingsTOMLCodec.encode(export, sharedWithOfficial: true)
        let raw = try TOMLDecoder().decode([String: TOMLNode].self, from: data)
        XCTAssertEqual(raw["schemaVersion"], .integer(4))
        guard case let .array(hotkeys) = raw["hotkeys"] else { return XCTFail("Missing hotkeys") }
        XCTAssertFalse(hotkeys.contains { entry in
            guard case let .table(row) = entry else { return false }
            return row["id"] == .string("moveWindowToMonitor.next")
        })

        // The official codec knows all shared fields and preserves the unknown Pebble table.
        var officialKnown = raw
        officialKnown.removeValue(forKey: "pebble")
        var editedByOfficial = officialKnown
        editedByOfficial["hotkeys"] = .array(hotkeys.map { entry in
            guard case var .table(row) = entry, row["id"] == .string("focusMonitorNext") else { return entry }
            row["binding"] = .string("Control+Command+Tab")
            return .table(row)
        })
        guard case var .table(gaps) = editedByOfficial["gaps"] else { return XCTFail("Missing gaps") }
        gaps["size"] = .integer(23)
        editedByOfficial["gaps"] = .table(gaps)
        let savedByOfficial = try TOMLNode.mergeUnknownKeys(
            base: editedByOfficial,
            oldRaw: raw,
            oldSchemaKnown: officialKnown
        )
        let officialData = try TOMLEncoder().encode(savedByOfficial)
        let reloaded = try SettingsTOMLCodec.decodeForLoad(officialData, sharedWithOfficial: true)
        XCTAssertNil(reloaded.migration)
        XCTAssertEqual(reloaded.export.gaps.size, 23)
        XCTAssertEqual(
            reloaded.export.hotkeyBindings.first { $0.id == "focusMonitorNext" }?.binding,
            try XCTUnwrap(HotkeyTrigger.fromHumanReadable("Control+Command+Tab"))
        )
        XCTAssertTrue(reloaded.export.hotkeyBindings.first { $0.id == "moveWindowToMonitor.next" }?.binding
            .isUnassigned == true)

        let savedByPebble = try SettingsTOMLCodec.encode(
            reloaded.export, preservingUnknownKeysFrom: officialData, sharedWithOfficial: true
        )
        XCTAssertEqual(
            try SettingsTOMLCodec.decodeForLoad(savedByPebble, sharedWithOfficial: true).export,
            reloaded.export
        )
        XCTAssertEqual(
            try TOMLDecoder().decode([String: TOMLNode].self, from: savedByPebble)["schemaVersion"],
            .integer(4)
        )
    }

    func testPreviousForkSchemaIsConvertedBackToSharedSchema() throws {
        let previous = try SettingsTOMLCodec.encode(SettingsExport.defaults(), sharedWithOfficial: false)
        let decoded = try SettingsTOMLCodec.decodeForLoad(previous, sharedWithOfficial: true)
        XCTAssertEqual(decoded.migration?.fromVersion, 5)
        XCTAssertEqual(decoded.migration?.toVersion, 4)
        let shared = try SettingsTOMLCodec.encode(
            decoded.export, preservingUnknownKeysFrom: decoded.migratedData, sharedWithOfficial: true
        )
        XCTAssertNil(try SettingsTOMLCodec.decodeForLoad(shared, sharedWithOfficial: true).migration)
        XCTAssertEqual(try SettingsTOMLCodec.decode(shared, sharedWithOfficial: true), decoded.export)
    }

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
