# CleanLock

A small macOS app that locks your keyboard and trackpad so you can wipe them down without typing or clicking anything.

## Features

- Lock the keyboard, the trackpad and mouse, or both
- Auto-unlock after 30 seconds, 1, 2 or 5 minutes
- Unlock early by holding both ⌘ keys for 2 seconds
- Keeps the display awake while locked

## Build

Requires macOS 13 or later and the Xcode Command Line Tools.

```sh
./build.sh
open CleanLock.app
```

## Permissions

CleanLock needs Accessibility access to block input. The first time you click **Lock**, allow it in System Settings > Privacy & Security > Accessibility, then click **Lock** again.

The app is signed ad hoc, so you may need to allow it again after rebuilding.

## License

[MIT](LICENSE)
