# Signing Deskterior with a free self-signed identity

Deskterior is distributed without a paid Apple Developer account. Every build is code-signed, by default
**ad-hoc** (`codesign --sign -`). An optional **self-signed** Code Signing certificate costs nothing and
makes updates smoother. This page explains why and how to set it up for local builds and the release
workflow.

## Why bother

macOS remembers privacy permissions (here: access to the Desktop folder) and the login item per app. It
identifies the app by its bundle id **and its designated requirement** (DR), the rule a signature must
satisfy to count as "the same app".

| Signature | Designated requirement (`codesign -d -r - Deskterior.app`) | After an update |
|---|---|---|
| Ad-hoc (default) | `cdhash H"…"` — the hash of this exact build | A different app to macOS: it may ask for Desktop access again, and a stale entry stays in System Settings |
| Self-signed | `identifier "io.github.<owner>.deskterior" and certificate root = H"…"` | Same DR for every build signed with the same certificate, so the permission carries over |

What it does **not** change:

- It is not a Developer ID certificate, and the app is still **not notarized**. Gatekeeper still blocks the
  first launch of every downloaded version, and users follow the *Open Anyway* steps in the release notes.
- Users cannot check who owns a self-signed certificate. To verify a download, use the provenance attestation
  instead: `gh attestation verify Deskterior-X.Y.Z.zip --repo <owner>/deskterior`.

Keep the same certificate for the life of the app. A new or renewed certificate changes the DR, so every user
is asked for Desktop access once more. `codesign` refuses an expired certificate, so pick a long validity and
back up the `.p12`.

## The bundle identifier

macOS keys permissions, settings (`~/Library/Preferences/<id>.plist`), the state folder
(`~/Library/Application Support/<id>`) and the login item to the bundle identifier, and the self-signed DR names it
too. `scripts/build-app.sh` picks it:

| Build | Bundle identifier |
|---|---|
| GitHub Actions (CI and releases) | `io.github.<owner>.deskterior`, `<owner>` lowercased from the checkout's `origin` remote, else `GITHUB_REPOSITORY_OWNER` |
| A local clone of the GitHub repository | the same, from its `origin` remote |
| A copy with no GitHub remote | `io.github.deskterior.dev`, a development id (the one unbundled `swift run` builds use), so a development build never shares settings or state with a released app |
| `BUNDLE_ID=…` set | that value |

The id is frozen at the first release. If the repository ever moves to another account, set `BUNDLE_ID` to the old
id in the release job's `env:` in `release.yml`, so the build and its Verify step both use it and users keep their
permissions, settings and layout.

## 1. Create the certificate (Keychain Access)

1. Open **Keychain Access**. On macOS 15 and later it is no longer in Utilities: use Spotlight, or run
   `open -a "Keychain Access"`.
2. Choose **Keychain Access › Certificate Assistant › Create a Certificate…**
3. Fill in:
   - **Name:** `Deskterior Self-Signed` (any name works; it shows up as the signing authority).
   - **Identity Type:** Self-Signed Root.
   - **Certificate Type:** Code Signing.
   - Tick **Let me override defaults** and set **Validity Period (days)** to `3650` (ten years). Accept the
     other defaults; the certificate goes into the **login** keychain.
4. Check that the identity exists:

   ```sh
   security find-identity -p codesigning
   ```

   It is listed, typically marked `CSSMERR_TP_NOT_TRUSTED`. That is fine: `codesign` can still sign with an
   untrusted self-signed certificate, so there is no need to mark it as trusted.

## 2. Sign local builds

```sh
SIGN_IDENTITY="Deskterior Self-Signed" make app
codesign -d -r - build/Deskterior.app
```

The second command prints `designated => identifier "…" and certificate root = H"…"`. The first signing asks for
permission to use the private key. Click **Always Allow**.

## 3. Export a .p12 for CI

1. In Keychain Access, select the **login** keychain and the **My Certificates** tab.
2. Right-click **Deskterior Self-Signed** and choose **Export "Deskterior Self-Signed"…**
3. Choose **File Format: Personal Information Exchange (.p12)** and save it, for example as
   `deskterior-signing.p12`.
4. Set a **non-empty password**. `security import` on CI cannot use a `.p12` with an empty password, and
   `scripts/ci-import-identity.sh` refuses one.

Keep the `.p12` and its password in a password manager. Anyone holding them can sign apps that macOS treats as
Deskterior when it checks permissions. Never commit the file.

## 4. Add the two repository secrets

With the GitHub CLI (`gh auth login` first), from the repository folder:

```sh
base64 -i deskterior-signing.p12 | gh secret set SIGNING_P12_BASE64
gh secret set SIGNING_P12_PASSWORD
```

The second command asks for the secret: paste the `.p12` password.

Or add them in the browser under **Settings › Secrets and variables › Actions › New repository secret**:

| Secret | Value |
|---|---|
| `SIGNING_P12_BASE64` | output of `base64 -i deskterior-signing.p12` |
| `SIGNING_P12_PASSWORD` | the password from step 3 |

Then delete the local `deskterior-signing.p12`; the backup lives in your password manager.

## How the release workflow uses them

`.github/workflows/release.yml` runs on `v*` tags:

1. The job sets `HAS_P12` from `secrets.SIGNING_P12_BASE64 != ''`, because secrets cannot be used in `if:`
   directly.
2. If the secret exists, `scripts/ci-import-identity.sh` decodes the `.p12` into a throwaway keychain with a
   random password. It imports the key for `/usr/bin/codesign` only, runs `set-key-partition-list` so signing
   needs no GUI prompt, puts the keychain first in the search list, and writes `SIGN_IDENTITY=<sha1>` to
   `$GITHUB_ENV`.
3. `scripts/build-app.sh` signs with `${SIGN_IDENTITY:--}`, so builds without the secret stay ad-hoc.
4. A final `if: always()` step runs `scripts/ci-import-identity.sh cleanup`, which deletes the keychain.

Secrets are not passed to workflows triggered from forks, and this workflow only runs for tags pushed to the
repository.

## Rotating or removing

- **Remove:** delete both secrets. The next release is ad-hoc signed again, and users are asked for Desktop
  access once after updating.
- **Rotate** (lost or expired certificate): create a new certificate and replace both secrets. Mention in the
  release notes that macOS will ask for Desktop access once more.
