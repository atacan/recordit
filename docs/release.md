## Releasing

Releases are automated via GitHub Actions. When a `v*` tag is pushed to `main`, the workflow builds arm64 and x86_64 binaries on macOS, creates a GitHub release, and updates the Homebrew formula.

### Version management

The single source of truth for the version is the `appVersion` constant in `Sources/record/record.swift` (line 3):

```swift
let appVersion = "0.1.0"
```

This value is:
- Embedded in the binary (`record --version`)
- Used in the GitHub release archives (e.g. `record-0.1.0-macos-arm64.tar.gz`)
- Written into the Homebrew formula

The tag name (`v0.1.0`) and the `appVersion` string (`0.1.0`) must match (minus the `v` prefix). The project uses [semantic versioning](https://semver.org).

### From a feature branch (recommended)

1. Bump `appVersion` in `Sources/record/record.swift`:
   ```swift
   let appVersion = "X.Y.Z"
   ```
2. Commit and push the branch:
   ```bash
   git add Sources/record/record.swift
   git commit -m "Release vX.Y.Z"
   git push origin my-branch
   ```
3. Open a PR and merge it into `main`.
4. Tag the merge commit on `main` and push the tag:
   ```bash
   git checkout main
   git pull origin main
   git tag -a vX.Y.Z -m "Release vX.Y.Z"
   git push origin vX.Y.Z
   ```

### Directly on main

If the only change is the version bump, you can skip the PR:

```bash
# edit Sources/record/record.swift → let appVersion = "X.Y.Z"
git add Sources/record/record.swift
git commit -m "Release vX.Y.Z"
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin main vX.Y.Z
```

> **Important:** The tag must point to a commit on `main`. If you tag a commit that hasn't been merged yet, the workflow will run but the release won't reflect the latest code.

### What the workflow does

1. Builds release binaries for arm64 and x86_64 on `macos-26`
2. Creates a GitHub release with per-architecture tar.gz archives
3. Generates and pushes the Homebrew formula to [atacan/homebrew-tap](https://github.com/atacan/homebrew-tap)

Users can then install or upgrade with:
```bash
brew install atacan/tap/record
brew upgrade record
```

### Local alternative

A `release.sh` script is available for doing the full release locally:

```bash
./release.sh X.Y.Z              # full release: build, tag, push, create release, update formula
./release.sh --formula-only X.Y.Z  # regenerate just the Homebrew formula from an existing release
```

The script updates `appVersion` in `Sources/record/record.swift` automatically via `sed`, so you don't need to edit the file manually when using it.

### First-time setup

The repo requires a `HOMEBREW_TAP_TOKEN` secret — a fine-grained PAT with Contents read+write access to `atacan/homebrew-tap`.
