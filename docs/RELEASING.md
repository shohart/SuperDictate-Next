# Releases: macOS and Windows

Both platforms publish to `shohart/SuperDictate-Next` and are told apart by
the tag prefix, never by which release GitHub calls "latest".

| Platform | Tag | Asset | GitHub "latest" | Who reads it |
|---|---|---|---|---|
| macOS | `mac-vX.Y.Z` (up to 0.7.0: `vX.Y.Z`) | `SuperDictate.zip` | yes | `UpdateCheck.parseReleases`, `install.sh`, `update.json` |
| Windows | `win-vX.Y.Z` | `SuperDictate-X.Y.Z-setup.exe` | **never** | `windows/superdictate/updater.py` |

- The macOS update check lists the releases and takes the newest published
  `mac-v*` / `v*` one, skipping Windows tags, drafts and pre-releases. It
  downloads `SuperDictate.zip` from that release's own tag, and the tag must
  name the version in `update.json`.
- The Windows update check takes the newest `win-v*` release only.
- `release-smoke.yml` runs for macOS tags only, and checks the published
  tag against `RELEASE_TAG` in `install.sh`.

## macOS

1. Build and sign, as before (`scripts/build-app.sh`, identity "PolterType Dev").
2. Put the version, `RELEASE_TAG="mac-vX.Y.Z"` and the zip's sha256 into
   `install.sh`, and the version and sha256 into `update.json`;
   `scripts/check.sh` checks that they agree. Add a CHANGELOG entry, commit.
3. `gh release create mac-vX.Y.Z SuperDictate.zip --target <full sha> --latest`

**One-time bridge.** macOS 0.7.0 and earlier read `releases/latest` and only
understand a `vX.Y.Z` tag, downloading from `releases/download/vX.Y.Z/`. So
the first release under the new scheme is published twice, with the same
`SuperDictate.zip`: as `mac-vX.Y.Z`, and as a legacy `vX.Y.Z` marked latest.
Once those clients have updated, they list releases themselves and plain
`v*` tags are no longer needed.

## Windows

On the Windows build machine, from `windows\`:

1. Bump `superdictate/version.py` and `AppVersion` in
   `installer/SuperDictate.iss` (the port follows the macOS version).
2. `.\build.ps1` (self-tests, the speech host, Silero VAD, PyInstaller),
   then `ISCC.exe installer\SuperDictate.iss` → `dist\SuperDictate-X.Y.Z-setup.exe`.
3. `gh release create win-vX.Y.Z SuperDictate-X.Y.Z-setup.exe --target <full sha> --latest=false`
   (add `--prerelease` for a test build). Never mark a Windows release
   latest: macOS 0.7.0 and earlier would read it as theirs.
