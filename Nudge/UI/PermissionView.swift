import SwiftUI

/// First-run window that explains the Accessibility permission.
struct PermissionView: View {
    let state: AppState
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Text("Nudge needs Accessibility access")
                    .font(.title2.bold())
            }

            Text("Nudge watches which text box you are typing in, so it can show its small icon next to it. macOS calls this Accessibility access.")

            Text("Nudge checks the box you click into to see if it holds text, and reads that text to rewrite it. While learning is on, it watches a rewrite for up to 90 seconds and saves short snippets on this Mac. It never sends your writing anywhere.")
                .foregroundStyle(.secondary)

            Button("Open System Settings", action: openSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Text("In System Settings, go to Privacy & Security, then Accessibility, and switch Nudge on. Nudge restarts itself once you do.")
                .font(.callout)

            Text(state.isTrusted ? "🟢 Accessibility is on" : "🔴 Accessibility is not on yet")
                .font(.headline)

            Text("Nudge already switched on, but this still says not on? The old permission is out of date. Select Nudge in the list, remove it with the minus button, then click Open System Settings again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
