# Contributing to Ledge

Thanks for wanting to help. Ledge is a small project, so the process is light.

## Before you start

- **Bugs:** open an issue with the bug template. Include your macOS version, your Mac model (notch or not), and what you expected to happen.
- **Features:** open an issue first to talk it through, so a pull request doesn't go to waste.
- **Privacy:** issues and pull requests are public. Leave out the titles of your windows, songs, events, notes and to-dos, and any log lines that contain them.

## Building

You need a Mac with Apple silicon on macOS 15 or later, and Xcode with Swift 6 (Ledge is built and tested with Xcode 27 and Swift 6.4).

```bash
git clone https://github.com/sabi1125/Ledge.git
cd Ledge
swift build
swift test
scripts/install.sh
```

`scripts/install.sh` builds a release copy, replaces `/Applications/Ledge.app` and opens it. See the README for signing your builds so macOS keeps Ledge's permissions between builds.

## Code layout

- `Sources/LedgeCore`: logic with no UI (parsing quick add, layout sizes, Vim motions, Markdown styling rules…). It has unit tests in `Tests/LedgeCoreTests`. Put new logic here when you can.
- `Sources/Ledge`: the app (SwiftUI and AppKit).
- `Bridge/`: the now-playing bridge (see the README for why it exists).

## Pull requests

- Keep each one focused on one change.
- Run `swift test` before you push, and add tests for logic in `LedgeCore`.
- Check how it looks: `.build/debug/Ledge --snapshot DIR` draws every island state to images with sample data.
- Write comments and user-facing text in plain, short sentences.
- Ledge uses some private macOS functions (listed in `Sources/Ledge/PrivateAPIs.swift`). If you add one, add it to that list and make the feature fall back cleanly when it's missing.

By contributing, you agree that your contributions are licensed under the MIT License.
