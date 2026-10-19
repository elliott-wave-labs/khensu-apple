# khensu-apple

khensu.nu for iPhone, iPad and Mac (`nu.khensu.ptah`). SwiftUI with stock Liquid Glass, iOS, iPadOS and macOS 26, dark only. The plan, protocol and threat model live in `khensu-specs`.

| Screen | |
| --- | --- |
| Onboarding, lock | `docs/screenshots/01-onboarding.png`, `02-lock.png` |
| Chats, conversation | `03-chats.png`, `04-conversation.png` |
| Add contact, safety number | `05-add-contact.png`, `06-safety-number.png` |
| Feed, Calls, Search | `07-feed.png`, `08-calls.png`, `09-search.png` |
| Settings, Devnet, About | `10-settings.png`, `11-devnet.png`, `12-about.png` |

## Install without the App Store

See [`docs/INSTALL.md`](docs/INSTALL.md): PWA at [waves.khensu.nu](https://waves.khensu.nu/), product page at [khensu.nu/moments](https://khensu.nu/moments), build from this repo, or sideload a Release IPA. Archive with `scripts/archive-waves.sh` / `scripts/archive-moments.sh` / `scripts/archive-ptah.sh`.

## Build

Needs Xcode 26.2 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is generated, not committed.

```sh
xcodegen generate
scripts/link-core.sh          # optional: link ../khensu-core (see below)
open Ptah.xcodeproj
```

Command line, for the three destinations the app ships on:

```sh
xcodebuild -project Ptah.xcodeproj -scheme Ptah -destination 'platform=iOS Simulator,name=iPhone Air' build
xcodebuild -project Ptah.xcodeproj -scheme Ptah -destination 'platform=macOS' build
xcodebuild -project Ptah.xcodeproj -scheme Ptah -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

Signing is automatic with team `LHS49D8RYY`.

## Layout

| Path | What |
| --- | --- |
| `App/` | The app target (iOS and macOS from one SwiftUI target) |
| `NotificationService/` | Notification Service Extension: shows a fixed "New message" and drops sealed packets into the App Group queue; nothing is decrypted there |
| `ShareExtension/` | Share Extension: hands text and links to the app as a draft |
| `Packages/KhensuKit/` | Everything below the UI: the `KhensuCore` protocol, `RustCore`, `MockCore`, device vault, incoming queue, contact invites, safety numbers |
| `PtahTests/` | Tests that need the app host: Secure Enclave keys, App Group, app lock and sealed state |
| `scripts/` | `link-core.sh`, `screenshots.sh`, `make-icon.swift` |

## Cores

The app talks to the protocol through `KhensuCore` (`Packages/KhensuKit/Sources/KhensuKit/Core.swift`). There are two implementations:

- **`RustCore`** wraps khensu-core's UniFFI API (`../khensu-core/ffi/SWIFT-API.md`): ML-DSA-87 identity, MLS with ML-KEM-1024, ~28 KB one-time contact cards, the Outfox tick schedule, and the post-quantum link to the gateway over QUIC (`GatewayLink.swift`, Network.framework).
- **`MockCore`** simulates the network on the device. It backs the demo mode, the screenshots and UI work.

`scripts/link-core.sh` symlinks `../khensu-core/target/KhensuCore.xcframework` and copies the generated `KhensuCore.swift` into the package (both git-ignored). When they are present, `Package.swift` adds the `KhensuCoreBindings` target and the app uses `RustCore`; otherwise it falls back to `MockCore`. Build khensu-core first with `./scripts/build-xcframework.sh` there, and rerun `link-core.sh` after every rebuild: the bindings check the library's API checksums at load. `scripts/link-core.sh --unlink` returns to `MockCore`. The launch argument `-KhensuMockCore YES` forces `MockCore` in a linked build.

To connect to a devnet: run `khensu-devnet`, then Settings > Network > Devnet and paste `devnet.json`, scan it as a QR code, or on the Simulator use "Load from Mac" (reads `../khensu-devnet/devnet.json`). On a device, start the devnet with `--host <Mac LAN IP>`.

## Tests

```sh
cd Packages/KhensuKit && swift test        # KhensuKit, including RustCore when linked
xcodebuild -project Ptah.xcodeproj -scheme Ptah -destination 'platform=macOS' test
xcodebuild -project Ptah.xcodeproj -scheme Ptah -destination 'platform=iOS Simulator,name=iPhone Air' test
```

On the Simulator the device vault uses software keys, because the iOS 26 Simulator refuses post-quantum Secure Enclave keys. The Secure Enclave paths run on a real iPhone (`-destination 'id=<UDID>' test`).

## Demo and screenshots

`-KhensuDemo YES` starts a seeded `MockCore` with software keys and no lock. `-KhensuTab chats|feed|calls|search|settings` and `-KhensuScreen onboarding|lock|conversation|addContact|safety|devnet|about` open a given screen. `scripts/screenshots.sh ["iPhone Air"]` rebuilds and captures `docs/screenshots/`.

## Not done in v0.1

- Recovery kit: khensu-core does not expose the recovery key yet, so onboarding with `RustCore` shows no words (with `MockCore` it shows the 24-word kit).
- Handles: `name.khensu.nu` is shown as pending; there is no key transparency lookup yet.
- Attachments: the photo picker is wired in the composer, but `RustCore` sends text only and `MockCore` stores a placeholder.
- Contact cards are ~28 KB, too large for one QR code, so with `RustCore` "My Code" shares a link instead. QR scanning still works for `MockCore` invites and devnet configs.
- Push: the Notification Service Extension queues sealed packets, but no push gateway sends them yet.
- Feed and Calls are placeholders. Groups and channels exist in khensu-core but have no UI yet.
- `RustCore` keeps message history and chat flags (pin, mute, archive) in its own sealed side state; khensu-core keeps only the protocol state.

## Licence

AGPL-3.0 (see `LICENSE` and `LICENSING.md`). khensu-core is Apache-2.0.
