# Packaging & signed releases

This repo builds the `container compose` plugin binary and, on a version tag,
ships a **signed + notarized + stapled `.pkg`** via `.github/workflows/release.yml`.

The Compose engine lives in a separate package,
[`ComposeKit`](https://github.com/flaticols/ComposeKit); this repo is a thin
ArgumentParser frontend that depends on it.

---

## 1. The ComposeKit dependency

`Package.swift` depends on ComposeKit over its Git URL, tracking `main` until the
first tagged release:

```swift
.package(url: "https://github.com/flaticols/ComposeKit.git", branch: "main"),
```

`Package.resolved` is **committed** (see `.gitignore`) so CI and release builds
pin the exact ComposeKit revision instead of floating to `main`'s HEAD.

**Local development against a ComposeKit working copy** — don't edit the line
above; override it with an editable checkout:

```sh
swift package edit ComposeKit --path ../ComposeKit   # use local ../ComposeKit
# ... hack on both repos ...
swift package unedit ComposeKit                       # back to the resolved revision
```

**At release time**, pin a version instead of the branch:

1. Tag ComposeKit: `git tag v0.1.0 && git push origin v0.1.0`.
2. In this repo, change the dependency to `from: "0.1.0"`.
3. `swift package resolve`, commit `Package.swift` + `Package.resolved`, push.

---

## 2. Apple certificates you need

Two Developer ID certs from your Apple Developer account
(<https://developer.apple.com/account/resources/certificates>):

| Cert | Signs | Used by |
|---|---|---|
| **Developer ID Application** | the `container-compose` Mach-O binary | `codesign` |
| **Developer ID Installer** | the `.pkg` | `productsign` |

Export each from Keychain Access as a `.p12` (right-click → Export, set a
password), then base64-encode for storage as a secret:

```sh
base64 -i DeveloperID_Application.p12 | pbcopy   # -> MACOS_APP_CERT_P12_BASE64
base64 -i DeveloperID_Installer.p12  | pbcopy    # -> MACOS_INSTALLER_CERT_P12_BASE64
```

## 3. Notarization credentials (App Store Connect API key)

Create an API key at
<https://appstoreconnect.apple.com/access/integrations/api> (role: Developer
is enough for notarization). You get a `.p8` file, a **Key ID**, and an
**Issuer ID**.

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy          # -> NOTARY_KEY_P8_BASE64
```

> Alternative (Apple ID): instead of the API key you can use
> `xcrun notarytool submit --apple-id <id> --team-id <TEAMID> --password <app-specific-pw>`.
> If you prefer this, replace the three `NOTARY_*` secrets and the `notarytool`
> invocation in `release.yml` accordingly.

## 4. GitHub repository secrets

Add under **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `MACOS_APP_CERT_P12_BASE64` | base64 of the Developer ID **Application** `.p12` |
| `MACOS_APP_CERT_P12_PASSWORD` | password you set when exporting it |
| `MACOS_INSTALLER_CERT_P12_BASE64` | base64 of the Developer ID **Installer** `.p12` |
| `MACOS_INSTALLER_CERT_P12_PASSWORD` | password you set when exporting it |
| `KEYCHAIN_PASSWORD` | any random string (temp keychain on the runner) |
| `NOTARY_KEY_ID` | App Store Connect API **Key ID** |
| `NOTARY_ISSUER_ID` | App Store Connect API **Issuer ID** |
| `NOTARY_KEY_P8_BASE64` | base64 of the `AuthKey_*.p8` |

If your `.pkg` identifier should differ from `dev.flaticols.container-compose`,
edit `PKG_IDENTIFIER` in `release.yml`.

---

## 5. Cutting a release

```sh
git tag v0.1.0
git push origin v0.1.0
```

The workflow then: builds a universal (arm64 + x86_64) release binary →
codesigns it with the hardened runtime → lays out the plugin payload →
`pkgbuild` → `productsign` → `notarytool submit --wait` → `stapler staple` →
uploads `container-compose-0.1.0.pkg` to the GitHub Release for that tag.

The `.pkg` installs the plugin to
`/usr/local/libexec/container-plugins/compose/` (matching `make install`). After
installing, reload plugins:

```sh
container system stop && container system start
container compose up
```
