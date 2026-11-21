import AppKit
import SwiftUI

/// The apps and websites where Nudge is fully off: no icon, no menu,
/// no double-tap, and nothing is read.
struct OffListView: View {
    @Bindable var store: ProfileStore
    let changed: () -> Void

    @State private var newSite = ""

    var body: some View {
        Form {
            Section {
                if store.profile.offApps.isEmpty {
                    Text("Nudge is on in every app.").foregroundStyle(.secondary)
                }
                ForEach(store.profile.offApps.sorted { $0.value < $1.value }, id: \.key) { id, name in
                    HStack {
                        Image(systemName: "app").foregroundStyle(.secondary)
                        Text(name)
                        Spacer()
                        Button {
                            store.profile.offApps[id] = nil
                            changed()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Turn Nudge back on here")
                    }
                }
                Menu("Add App") {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "App") { add(app) }
                    }
                }
                .fixedSize()
            } header: {
                Text("Apps")
            }

            Section {
                if store.profile.offSites.isEmpty {
                    Text("Nudge is on on every website.").foregroundStyle(.secondary)
                }
                ForEach(store.profile.offSites, id: \.self) { site in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                        Text(site)
                        Spacer()
                        Button {
                            store.profile.offSites.removeAll { $0 == site }
                            changed()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Turn Nudge back on here")
                    }
                }
                HStack {
                    TextField("Website", text: $newSite, prompt: Text("mybank.com"))
                        .onSubmit(addSite)
                    Button("Add Website", action: addSite)
                        .disabled(siteHost == nil)
                }
            } header: {
                Text("Websites")
            } footer: {
                Text("A website covers its subdomains too, so mybank.com also covers online.mybank.com. Password fields are always skipped, everywhere.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 380)
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { store.profile.offApps[$0.bundleIdentifier ?? ""] == nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func add(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        store.profile.offApps[id] = app.localizedName ?? id
        changed()
    }

    /// "https://www.mybank.com/login" or "mybank.com" both become "mybank.com".
    private var siteHost: String? {
        let text = newSite.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let host = URL(string: withScheme)?.host(), host.contains(".") else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func addSite() {
        guard let host = siteHost, !store.profile.offSites.contains(host) else { return }
        store.profile.offSites.append(host)
        newSite = ""
        changed()
    }
}
