# Keyboard Manager — manual phase 1

Run after Raycast is open and its Caps Lock Hyper Key is working, including after
reconnecting the Microsoft keyboard or restarting the Mac. This command runs once
and exits. Automatic startup/reconnect handling is deferred.

## Build and use

```sh
mkdir -p build
swiftc -O main.swift -import-objc-header BridgingHeader.h -framework IOKit -o build/keyboard-manager
./build/keyboard-manager --apply
```

`--apply` saves rollback data automatically under
`~/Library/Application Support/KeyboardManager/Rollbacks/` before changing any
service. It prints the path; no journal file is written for a no-op run.
Running repeatedly does not add duplicates. No arguments prints help.

Other commands:

```sh
./build/keyboard-manager --inspect
./build/keyboard-manager --self-test
./build/keyboard-manager --restore /absolute/path/to/rollback.plist
./build/keyboard-manager --once --journal /absolute/path/to/new-journal.plist
```

Apply reports a nonzero exit status if a supported keyboard is skipped because
its baseline is unavailable/ambiguous, it has a conflict, or a write fails.
Start Raycast/check Hyper Key, then rerun. It never creates Raycast's baseline.
A successful update to another keyboard is not undone if one keyboard fails.

## Raycast shortcut

`scripts/apply-keyboard-mappings.sh` is a Raycast Script Command named **Apply
Keyboard Mappings**. Add this project's `scripts` folder as a Script Directory
in Raycast, then invoke that command. The script executes the existing build;
it does not compile on each invocation. Keep it in the project's scripts folder.

Format reference: https://github.com/raycast/script-commands

## What is changed

Only keyboard services with these exact product names are eligible:

- Apple Internal Keyboard / Trackpad
- Natural® Ergonomic Keyboard 4000

The `2.4G Receiver` is excluded, despite exposing a keyboard interface.

The required Raycast baseline is exactly one of each:

| Source | Destination |
| --- | --- |
| Caps Lock `0x700000039` | Right Control `0x7000000E4` |
| Right Control `0x7000000E4` | Left Control `0x7000000E0` |

The command appends Right Command `0x7000000E7` → Right Control `0x7000000E4`.
An identical existing mapping is a no-op. Conflicting/duplicate Right Command
entries, ambiguous baseline entries, or malformed entries prevent a write.
Existing entries, their order, and extra fields are preserved.

## Rollback and limits

Restore uses the saved registry ID and product to identify the same connected
service, and restores only if its entire current array equals our recorded
post-write array. If Raycast changed the array or a keyboard reconnected, it
skips that record instead of overwriting newer state. A journal only reverses
changes made during that particular invocation.

Before writing, the command rereads the array, and afterward verifies readback.
IOKit offers no atomic compare-and-swap here: a concurrent writer can still race
between the final read and write. Run after Raycast has finished configuring
Hyper Key. The command does not observe key presses or request input capture.

## Understanding the implementation

- `plan` is a pure Swift function: it decides whether an array needs an additional
  entry without accessing hardware. Its tests can safely cover conflicts.
- Foundation bridges Core Foundation arrays/dictionaries to `NSArray` and
  `NSDictionary`. Copying the original array preserves entries we do not own.
- `BridgingHeader.h` exposes Apple's C APIs to Swift. The public simple HID client
  reads/writes service properties; there are no private API declarations.
- An IOKit service is a logical interface, not always an entire physical device.
  That is why checking for a keyboard interface alone would include the mouse.
- There is no background process, notification observer, timer, or LaunchAgent.
  Future `launchd` integration would have to address Raycast readiness explicitly;
  launching at login by itself does not ensure the baseline is ready.

## Validation

The manual version compiles with optimization and passes 13 mapping-policy tests.
Earlier live tests verified append and rollback on both keyboards and exclusion
of the receiver. Raycast restart preserved the custom mappings in live testing.
Automatic reconnect/startup experiments failed to reliably observe baseline
readiness and have been removed from the manual version.
