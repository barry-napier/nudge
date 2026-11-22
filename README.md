# Nudge

A private writing assistant for your Mac. Nudge fixes, shortens and rewrites
text in almost any app, using Apple's AI model on your Mac. It never sends
your writing anywhere.

**[nudge.bnapier.dev](https://nudge.bnapier.dev)**

- **Works everywhere you type.** Mail, Notes, Slack, Messages, Safari, Chrome.
- **Keyboard first.** Double-tap the right Option key, pick an action, done.
- **Sounds like you.** A writer profile sets your tone, spelling, banned words,
  and a voice per app or website.
- **Learns.** Nudge notices what you keep, edit and undo, and suggests style
  rules. You keep or dismiss each one.
- **Private.** No account, no server, no tracking. The code is open, so you can
  check.

## Install

[Download Nudge](https://github.com/barry-napier/nudge/releases/latest/download/Nudge.dmg),
open it, and drag
Nudge to Applications. Nudge updates itself.

Or with Homebrew, once the cask is published:

```sh
brew install --cask nudge
```

Needs macOS 26 or later, an Apple Silicon Mac, and Apple Intelligence turned
on.

## Use

1. Click into any text box. A small ✦ appears in its corner.
2. Double-tap the right Option key, or click the ✦.
3. Pick an action with the arrow keys and Return, or press 1 to 8:
   Fix spelling and grammar, Make concise, Improve writing, Formal, Casual,
   Friendly, Direct, or a custom instruction.
4. Changed your mind? Open the menu again and choose Undo.

The ✦ in the menu bar has your writer profile, what Nudge learned, and
settings. Right Control works as the trigger too.

To turn Nudge off somewhere, open the ✦ menu while you're in that app and
choose **Turn Off in [app]**, or **Turn Off on [website]** in a browser.
**Where Nudge Is Off…** lists them all. Where Nudge is off, it shows nothing,
ignores the double-tap, and reads no text. A website covers its subdomains too.

## Privacy

- Text is rewritten by Apple's on-device model. It is never sent anywhere.
- When you click into a box, Nudge checks whether it holds text. For some
  kinds of box that means reading the value for a moment. It is not kept.
- Nudge reads a box's text to rewrite it. While learning is on, it also reads
  that box for up to 90 seconds afterwards, and saves short snippets on your
  Mac. You can turn learning off or delete what it saved.
- Password fields are skipped.
- To paste in browsers and some apps, Nudge uses the clipboard for a moment and
  then puts yours back. Both are marked for this Mac only, so Universal
  Clipboard does not copy them to your other devices.
- Your profile and what Nudge learns are stored only in
  `~/Library/Application Support/Nudge`. You can see, edit, export or delete
  all of it.
- The only network use is updates: checking for them and downloading them from
  this repository's releases.
- The debug log is in `~/Library/Logs/Nudge`. Public builds never put your
  text in it.

## Why not the Mac App Store?

The App Store requires the app sandbox, which blocks the system-wide
Accessibility access Nudge needs to work in other apps.

## Build from source

You need Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) and an Apple Development certificate.

```sh
./scripts/build.sh
```

This builds, signs with your certificate, installs to `/Applications`, and
relaunches Nudge. Always use it for test builds: a stable path and signature
keep macOS from forgetting the Accessibility permission. On first run it writes
your Team ID to `Config/Local.xcconfig`, which is not committed.

The Xcode project is generated from `project.yml`. Edit that, not the project.

### Debugging

**Show Debug Log** in the menu bar menu lists what Nudge saw and did. The same
log is in `~/Library/Logs/Nudge/nudge.log`. Debug builds also have **Log Text
for Testing**, which adds the text of each rewrite to the log.

If the permission goes stale, remove Nudge from System Settings > Privacy &
Security > Accessibility with the minus button, then relaunch it. Last resort:

```sh
tccutil reset Accessibility com.barrynapier.nudge
```

### Self-test (debug builds only)

```sh
./scripts/selftest.sh
```

Opens its own TextEdit file, then rewrites, edits and undoes text, checks what
Nudge recorded, runs a learning pass, and cleans up. It only touches its own
file: every step checks its target at the moment it acts. Don't type while it
runs.

## Website

[nudge.bnapier.dev](https://nudge.bnapier.dev) is the plain HTML in `site/`,
hosted on Vercel. There is no build step: open `site/index.html` to preview it.

## Releasing

Releases are built by GitHub Actions. To ship a new version:

```sh
./scripts/ship.sh 0.2.0
```

That pushes `main` and a `v0.2.0` tag. The [Release workflow](.github/workflows/release.yml)
then builds Nudge, signs it with Developer ID, has Apple notarize it, packs the
DMG, signs it for Sparkle, and publishes the GitHub release with
`appcast.xml`. Installed copies of Nudge check
`releases/latest/download/appcast.xml` and offer the update by themselves. You
can also start a release from GitHub: Actions, Release, Run workflow.

The workflow needs these repository secrets: `MACOS_CERT_P12`,
`MACOS_CERT_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD` and
`SPARKLE_PRIVATE_KEY`. The workflow file says what each one is.

To build a release on a Mac instead, without publishing:

```sh
./scripts/release.sh 0.2.0                  # needs: xcrun notarytool store-credentials nudge-notary
./scripts/release.sh 0.2.0 --skip-notarize  # quick local check
```

Keep a backup of the Sparkle update key (`generate_keys --account
com.barrynapier.nudge -x FILE`) somewhere safe. Without it, no update can ever
reach people who already installed Nudge.

## License

MIT. See [LICENSE](LICENSE).
