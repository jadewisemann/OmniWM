// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

// Official v0.7.4 requires schema 4 and rejects unknown action IDs in [[hotkeys]].
// Its unknown-key preservation keeps the Pebble table when the official app saves.
enum SettingsTOMLSharedConfig {
    static let schemaVersion = 4
    private static let moveActionID = "moveWindowToMonitor.next"

    static func sharedTree(_ raw: [String: TOMLNode]) -> [String: TOMLNode] {
        var result = raw
        guard case .integer(5) = raw["schemaVersion"], case let .array(entries) = raw["hotkeys"] else {
            return result
        }
        let forkEntries = entries.filter(isForkHotkey)
        result["hotkeys"] = .array(entries.filter { !isForkHotkey($0) })
        var pebble: [String: TOMLNode] = [:]
        if case let .table(existing) = raw["pebble"] { pebble = existing }
        pebble["hotkeys"] = .array(forkEntries)
        result["pebble"] = .table(pebble)
        result["schemaVersion"] = .integer(Int64(schemaVersion))
        return result
    }

    static func decodeForLoad(_ raw: [String: TOMLNode], version: Int) throws -> SettingsTOMLDecodeResult {
        var restored = raw
        if version <= schemaVersion,
           case let .table(pebble) = raw["pebble"],
           let forkHotkeys = pebble["hotkeys"],
           case var .array(entries) = raw["hotkeys"]
        {
            guard case let .array(forkEntries) = forkHotkeys, forkEntries.allSatisfy(isForkHotkey) else {
                throw SettingsTOMLCodecError
                    .migrationInvariant("pebble.hotkeys must contain only Pebble hotkey entries.")
            }
            entries.append(contentsOf: forkEntries)
            restored["hotkeys"] = .array(entries)
            if version == schemaVersion, !forkEntries.isEmpty {
                // This file already passed the Pebble migration. Respect subsequent
                // official-app edits, including restoring its old focus shortcut.
                restored["schemaVersion"] = .integer(Int64(SettingsTOMLCodec.currentSchemaVersion))
            }
        }
        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let restoredData = try encoder.encode(restored)
        let decoded = try SettingsTOMLCodec.decodeForLoad(restoredData, sharedWithOfficial: false)
        // Loading an official schema-4 file adds Pebble defaults in memory only.
        // Avoid a migration/backup on every alternating launch.
        guard version != schemaVersion else {
            return SettingsTOMLDecodeResult(export: decoded.export, migration: nil, migratedData: nil)
        }
        let report = decoded.migration
        return SettingsTOMLDecodeResult(
            export: decoded.export,
            migration: SettingsMigrationReport(
                fromVersion: version,
                toVersion: schemaVersion,
                defaultedPaths: report?.defaultedPaths ?? [],
                addedHotkeyIDs: report?.addedHotkeyIDs ?? [],
                mappedHotkeys: report?.mappedHotkeys ?? [],
                retiredHotkeys: report?.retiredHotkeys ?? []
            ),
            migratedData: decoded.migratedData ?? restoredData
        )
    }

    private static func isForkHotkey(_ entry: TOMLNode) -> Bool {
        guard case let .table(table) = entry else { return false }
        return table["id"] == .string(moveActionID)
    }
}
