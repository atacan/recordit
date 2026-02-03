# recordit

A small macOS CLI that records audio from the default microphone and prints the output file path.

## Build

```bash
swift build
```

## Run

```bash
.build/arm64-apple-macosx/debug/recordit
```

The command prints the output file path to stdout. Status messages go to stderr so the output is pipeline-friendly.

## Usage

```bash
recordit [--duration <seconds>] [--output <path>] [--name <pattern>] [--overwrite] [--json] [--sample-rate <hz>] [--channels <count>] [--bit-rate <bps>] [--format <format>] [--quality <quality>]
```

## Options

- `--duration <seconds>`: Stop automatically after this many seconds. If omitted, press `S` to stop.
- `--output <path>`: Write output to this file or directory. Default: temporary directory.
- `--name <pattern>`: Filename pattern when output is a directory. Supports strftime tokens and `{uuid}`. Default: `micrec-%Y%m%d-%H%M%S`.
- `--overwrite`: Overwrite output file if it exists.
- `--json`: Print machine-readable JSON to stdout.
- `--sample-rate <hz>`: Sample rate in Hz. Default: `44100`.
- `--channels <count>`: Number of channels. Default: `1`.
- `--bit-rate <bps>`: Encoder bit rate in bps. Default: `128000`. Ignored for `linearPCM`.
- `--format <format>`: Audio format. Default: `linearPCM`.
- `--quality <quality>`: Encoder quality. Default: `high`.

Supported formats:
- `aac`, `alac`, `linearPCM`, `appleIMA4`, `ulaw`, `alaw`

File extension mapping:
- `aac`, `alac` -> `.m4a`
- `linearPCM`, `appleIMA4`, `ulaw`, `alaw` -> `.caf`

## Examples

```bash
recordit --duration 5
recordit --output /tmp --name "micrec-%Y%m%d-%H%M%S-{uuid}"
recordit --output /tmp/meeting.caf --overwrite
recordit --duration 5 --json
recordit --sample-rate 48000 --channels 2 --format aac --quality high
recordit --format linearPCM --sample-rate 44100 --channels 1
```

## Notes

- Microphone permission is required. In macOS: System Settings -> Privacy & Security -> Microphone -> enable your terminal app.
- Stopping with `S` requires a real TTY (Terminal/iTerm). IDE consoles may not deliver single-key input.
