# Nudge

A private, on-device writing helper for macOS. Nudge shows a small icon next to
the text field you are typing in, in any app. Nothing leaves your Mac.

Status: **Stage 1**. The icon appears and hides with focus. It does not read or
change text yet.

## Requirements

- macOS 26 or later on Apple Silicon
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An Apple Development certificate in your keychain

## Build and run

```sh
./scripts/build.sh
```

The script builds, signs with your Apple Development certificate, installs to
`/Applications/Nudge.app`, and relaunches it. Always use it for test builds.
A stable path and signature keep macOS from forgetting the Accessibility
permission. On first run it writes your Team ID to `Config/Local.xcconfig`,
which is not committed.

You can also open `Nudge.xcodeproj` in Xcode. The project is generated from
`project.yml`, so edit that file, not the project.

## Debugging

The menu bar menu has **Show Debug Log**. It lists the app, role and frame of
each focused element. The same log is written to `~/Library/Logs/Nudge/nudge.log`.
It never records what you type.

If permissions go stale, quit Nudge, remove it from System Settings > Privacy &
Security > Accessibility with the minus button, then relaunch it. Last resort:

```sh
tccutil reset Accessibility com.barrynapier.nudge
```
