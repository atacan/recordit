# AGENTS.md

## Project summary

recordit is a macOS CLI that records audio from the default microphone using AVFoundation and prints the output file path to stdout. Status messages go to stderr to keep stdout pipeline-friendly.

## Key files

- `Sources/recordit/recordit.swift`: Entry point and CLI implementation.
- `Package.swift`: SwiftPM manifest.

## Build and run

```bash
swift build
.build/arm64-apple-macosx/debug/recordit --duration 5
```

## CLI behavior

- Argument parsing uses Swift Argument Parser (`AsyncParsableCommand`).
- Default audio settings:
  - format: `linearPCM`
  - sample rate: `44100`
  - channels: `1`
  - bit rate: `128000` (ignored for `linearPCM`)
  - quality: `high`
- Output extension:
  - `aac`, `alac` -> `.m4a`
  - `linearPCM`, `appleIMA4`, `ulaw`, `alaw` -> `.caf`
- Recording stops on `S` or when `--duration` expires.
- Single-key input uses raw terminal mode and `poll` on stdin; it requires a real TTY.
- Output control:
  - `--output` accepts a file or directory path. Directories use the name pattern.
  - `--name` supports strftime tokens plus `{uuid}`.
  - `--overwrite` allows replacing an existing file.
  - `--json` prints structured output to stdout instead of just the path.

## Testing notes

- Microphone permission must be granted to the terminal app or the command exits with code 2.
- When updating options or defaults, keep help text in sync and update `README.md`.
