# Contributing to Keeper

Thanks for helping make culling faster for everyone.

## Setup

```bash
swift build          # debug build of everything
swift test           # unit tests for KeeperCore
./Scripts/build-app.sh --run
```

You need macOS 14+ and Xcode command-line tools. There are no third-party dependencies.

## Project layout

- `Sources/KeeperCore`: UI-free logic. New logic belongs here with a test whenever possible.
- `Sources/Keeper`: SwiftUI app. `Library` owns state and actions; views stay thin.
- `Sources/KeeperDemoGen`: makes a fake shoot (synthetic ARW files) so nobody needs a camera to develop.

## Trying changes without a camera

```bash
swift run -c release KeeperDemoGen ./DemoShoot
KEEPER_OPEN=./DemoShoot dist/Keeper.app/Contents/MacOS/Keeper
```

### Headless UI snapshots

The app can render its own window to PNG without any screen-recording permission:

```bash
KEEPER_OPEN=./DemoShoot KEEPER_SNAPSHOT_DIR=./docs/screenshots dist/Keeper.app/Contents/MacOS/Keeper
```

Add `KEEPER_SELFTEST_TRASH=1` (against a **copy** of your photos!) to also run an end-to-end trash-then-undo check.

## Reporting RAW problems

Different cameras lay out their embedded previews differently. If a file is slow, upside-down or shows no preview, open an issue with the camera model and, if you can share it, the output of:

```bash
exiftool -a -G1 -s -PreviewImage -JpgFromRaw -ThumbnailImage -Orientation yourfile.ARW
```

## Pull requests

- Keep PRs focused; add or update tests in `Tests/KeeperCoreTests` for core changes.
- Match the surrounding style. UI colours and spacing come from `Theme.swift`.
- Anything that deletes or overwrites user files needs a confirmation step and an undo path.
