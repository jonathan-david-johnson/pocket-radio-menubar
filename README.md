# PocketRadio Menubar

macOS menubar app for PocketRadio — play your top Pocket Casts up-next podcast and favorite radio streams.

## Status

- [x] M1: Skeleton menubar plays hardcoded stream
- [ ] M2: Pocket Casts login + token persistence
- [ ] M3: Up-next podcast playback
- [ ] M4: Radio favorites from Supabase
- [ ] M5: Now-playing metadata + polish

## Build

```bash
xcodebuild -project PocketRadio.xcodeproj -scheme PocketRadio -configuration Debug build
```

Or open `PocketRadio.xcodeproj` in Xcode and press Cmd+R.

## Architecture

See [docs/menubar/README.md](docs/menubar/README.md) for full architecture documentation.
