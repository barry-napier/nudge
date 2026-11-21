import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Loads and saves the writer profile as JSON in
/// ~/Library/Application Support/Nudge/profile.json. It never leaves the Mac.
@MainActor
@Observable
final class ProfileStore {
    static let shared = ProfileStore()

    var profile: WriterProfile {
        didSet {
            if profile != oldValue { save() }
        }
    }

    let fileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Nudge/profile.json")

    private init() {
        profile = WriterProfile()
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            profile = try JSONDecoder().decode(WriterProfile.self, from: data)
        } catch {
            // Keep the unreadable file so nothing is lost, and start fresh.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            Log.shared.add("Writer profile could not be read. Saved a copy as \(backup.lastPathComponent) and started fresh.")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoded(profile).write(to: fileURL, options: .atomic)
        } catch {
            Log.shared.add("Could not save the writer profile: \(error.localizedDescription)")
        }
    }

    private func encoded(_ profile: WriterProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }

    // MARK: - Export and import

    func exportProfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Nudge Writer Profile.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try encoded(profile).write(to: url, options: .atomic)
            Log.shared.add("Writer profile exported")
        } catch {
            alert("Nudge could not export the profile.", error.localizedDescription)
        }
    }

    func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var imported = try JSONDecoder().decode(WriterProfile.self, from: Data(contentsOf: url))
            imported.hasCompletedOnboarding = true
            profile = imported
            Log.shared.add("Writer profile imported")
        } catch {
            alert("That file is not a Nudge writer profile.", error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
