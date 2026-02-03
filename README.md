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
recordit [--duration <seconds>] [--output <path>] [--name <pattern>] [--overwrite] [--json] [--list-devices] [--list-formats] [--list-qualities] [--device <device>] [--sample-rate <hz>] [--channels <count>] [--bit-rate <bps>] [--format <format>] [--quality <quality>]
```

## Options

- `--duration <seconds>`: Stop automatically after this many seconds. If omitted, press `S` to stop.
- `--output <path>`: Write output to this file or directory. Default: temporary directory.
- `--name <pattern>`: Filename pattern when output is a directory. Supports strftime tokens and `{uuid}`. Default: `micrec-%Y%m%d-%H%M%S`.
- `--overwrite`: Overwrite output file if it exists.
- `--json`: Print machine-readable JSON to stdout.
- `--list-devices`: List available input devices and exit.
- `--list-formats`: List available audio formats and exit.
- `--list-qualities`: List available encoder qualities and exit.
- `--device <device>`: Input device UID or name to use for recording.
- `--stop-key <char>`: Stop key (single ASCII character). Default: `s` (case-insensitive).
- `--pause-key <char>`: Pause key (single ASCII character). Default: `p` (case-insensitive). If same as resume key, toggles pause/resume.
- `--resume-key <char>`: Resume key (single ASCII character). Default: `r` (case-insensitive). If same as pause key, toggles pause/resume.
- `--silence-db <db>`: Silence threshold in dBFS (e.g. `-50`). Requires `--silence-duration`.
- `--silence-duration <seconds>`: Stop after this many seconds of continuous silence. Requires `--silence-db`.
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
recordit --list-devices
recordit --list-formats --json
recordit --device "MacBook Pro Microphone" --duration 10
recordit --stop-key q --duration 30
recordit --pause-key p --resume-key r
recordit --pause-key p --resume-key p
recordit --silence-db -50 --silence-duration 3
recordit --output /tmp --name "micrec-%Y%m%d-%H%M%S-{uuid}"
recordit --output /tmp/meeting.caf --overwrite
recordit --duration 5 --json
recordit --sample-rate 48000 --channels 2 --format aac --quality high
recordit --format linearPCM --sample-rate 44100 --channels 1
```

## Notes

- Microphone permission is required. In macOS: System Settings -> Privacy & Security -> Microphone -> enable your terminal app.
- Stopping with `S` requires a real TTY (Terminal/iTerm). IDE consoles may not deliver single-key input.
