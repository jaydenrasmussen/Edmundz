# Edmundz

A native macOS Markdown editor where the editor is the rendered document. Your file opens already rendered; click a word and the
syntax appears only where you are. GitHub Flavored Markdown, front-matter, Mermaid, LaTeX, images, tables, callouts and more.

Requires macOS 26 and an Apple silicon Mac.

## Build

Needs Swift 6.2 and [Task](https://taskfile.dev).

```sh
task            # list tasks
task test       # unit tests
task bench      # performance gates and behavior checks (fails on a miss)
task check      # tests + bench
task bundle     # build/Edmundz.app (direct channel, ad-hoc signed)
task run -- examples/sample.md
```

Mermaid and KaTeX are downloaded once into `Resources/` by `task vendor` (`task bundle` runs it when they are missing).
`task bundle:mas` builds the Mac App Store variant (sandbox entitlements, no Sparkle), `task dmg` makes a disk image, and
`task notarize` signs and notarizes the direct build (see below).

## Releases

Releases are cut from GitHub, not from a laptop:

1. Open **Actions → Cut release → Run workflow** and choose **patch**, **minor** or **major**.
2. The workflow works out the next `vX.Y.Z` from the latest tag, tags the current commit, and creates the GitHub release with
   automatically generated notes (grouped by PR label; see `.github/release.yml`).
3. It then builds the app and attaches `Edmundz-X.Y.Z.dmg`, `Edmundz-X.Y.Z-macOS.zip` and `SHA256SUMS.txt` to the release.

Publishing a release by hand in the GitHub UI runs the same build. `CI` builds and tests every push and pull request.

Without signing secrets the build is ad-hoc signed and not notarized. To sign and notarize, add these repository secrets:

| Secret | What it is |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application certificate (.p12), base64-encoded |
| `P12_PASSWORD` | password of that .p12 |
| `KEYCHAIN_PASSWORD` | any password for the temporary CI keychain |
| `DEVELOPER_ID` | the identity name, e.g. `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | notarization credentials (an app-specific password) |

Set `SUFeedURL` and `SUPublicEDKey` in `scripts/bundle.sh` to enable Sparkle updates in the direct build.

## Known limitations

- Performance is measured on an M2 Pro, not yet on an M1 with 8 GB. Typing p99 is about 2 ms and a 1 MB file opens in about 40 ms.
- Hard-wrapped paragraphs show their source line breaks: each source line is laid out as its own block, so lines cannot reflow.
- Code highlighting is a small built-in tokenizer, not a grammar-based one.
- The Quick Look extension is built and registered but has not been verified in Finder.
- IME and VoiceOver are covered by programmatic checks, not by a session with a real input method or screen reader.

## License

[MIT](LICENSE). Third-party software is listed in the About window and in `Resources/licenses`.
