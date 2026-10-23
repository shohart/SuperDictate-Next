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

1. Bump `swift/Info.plist`. Build and sign in the main checkout, not in a
   temporary worktree or clone:
   `SIGN_IDENTITY=C78D9D87EB6EC8BF75D2DF035A59D6FB300C9ED9 scripts/build-app.sh`
   (the "PolterType Dev" certificate, by hash: its name is ambiguous in
   the keychain). Then zip it:
   `ditto -c -k --sequesterRsrc --keepParent dist/SuperDictate.app dist/SuperDictate.zip`.
2. **Self-tests from the build tree, with the real models** (`swift build -c debug`
   first). These must pass: `all`, `llm-guardrail`, `llm-gec`, `llm-rewrite`,
   `llm-prefix-primer`, `full-pipeline`; the environment variables they need are
   printed in each suite's SKIP line. `all` and `update` can boot the
   production agent out: afterwards check
   `launchctl list | grep superdictate` and restore it if it is gone.
3. **`scripts/verify-release.sh dist/SuperDictate.zip` must pass. This step is
   mandatory.** It unpacks the zip into a fresh directory and checks that
   exact artifact through its own binaries. It checks the signature and
   designated requirement, the helpers, and the LLM Vulkan shaders in the
   bundle. It starts the GPU host from the bundle. It runs correction on the
   GPU and the CPU and rewrite on the GPU through the real coordinator
   (`--diagnose-llm`). It also runs Parakeet and GigaAM on a `say` recording.
   Self-tests alone are not enough. mac-v0.8.4 passed all of them and still
   crashed on every GPU start: its shaders were missing from the bundle and
   were found only in the build tree, a worktree that was deleted after the
   build.
4. Put the version, `RELEASE_TAG="mac-vX.Y.Z"` and the zip's sha256 into
   `install.sh`, and the version and sha256 into `update.json`;
   `scripts/check.sh` checks that they agree. Add a CHANGELOG entry and
   commit (S). In a second commit, set `SOURCE_COMMIT=S` in `install.sh`.
5. `gh release create mac-vX.Y.Z dist/SuperDictate.zip --target <full sha of the second commit> --latest`,
   then `gh workflow run "release smoke"` (Actions do not trigger on their
   own in this repo) and wait for it to pass.
6. Pushes from this Mac go over HTTPS (the SSH key is a read-only deploy key):
   `git -c credential.helper='!gh auth git-credential' push https://github.com/shohart/SuperDictate-Next.git main`.

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
