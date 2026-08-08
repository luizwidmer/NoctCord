# Contributing to Noct Cord

Thank you for helping improve Noct Cord. The project is pre-1.0; keep changes
small, reviewable, and explicit about compatibility and security boundaries.

## Development

Use Swift 6 and provide a local Noctweave checkout when testing protocol work:

```sh
export NOCTWEAVE_PACKAGE_PATH="/path/to/NoctweaveCore"
swift build
swift test
```

Run the macOS bundle script only after package tests pass:

```sh
Scripts/build-macos-app.sh debug
```

## Change requirements

- Preserve group-scoped identities and end-to-end encryption.
- Never add plaintext relay processing, hidden third-party STUN/TURN defaults,
  analytics, or silent security downgrades.
- Add focused tests for codec, projection, transport, attachment, or media
  behavior changed by the contribution.
- Update the README or relevant file under `docs/` when behavior or security
  claims change.
- Keep generated build output and local credentials out of Git.

Report vulnerabilities according to `SECURITY.md`, not in a public issue.

## License of contributions

By submitting a contribution, you agree that it may be distributed under the
GNU Affero General Public License v3.0 or later (`AGPL-3.0-or-later`).
