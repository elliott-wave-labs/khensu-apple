# Install khėnsu.ñü and nu.waves from GitHub

Source of truth: [github.com/elliott-wave-labs/khensu-apple](https://github.com/elliott-wave-labs/khensu-apple). The App Store is the usual path when Apple lists the apps; this page is the fallback when it does not, and for anyone who wants to build from the same tree we ship.

## Fast path (no Xcode)

1. Open [waves.khensu.nu](https://waves.khensu.nu/) in Safari on iPhone or iPad.
2. Share → **Add to Home Screen**. That is the nu.waves PWA; it plays without the App Store.
3. For the messenger, use the site until an IPA or App Store listing is live: [khensu.nu](https://khensu.nu/).

## Install an IPA from a GitHub Release

When a Release on this repo attaches `nu.waves.ipa` or `khensu.nu.ipa`:

1. On a Mac with a free or paid Apple ID, install [Sideloadly](https://sideloadly.io/) or [AltServer](https://altstore.io/).
2. Download the `.ipa` from the Release assets.
3. Sideload to your unlocked iPhone (USB). Free Apple IDs need a re-sign about every 7 days; a paid Developer account lasts a year for ad-hoc devices you register.

We never ask for your Apple password on our servers. Signing happens on your Mac.

## Build and run from source (Xcode 26.2+)

```sh
git clone https://github.com/elliott-wave-labs/khensu-apple.git
git clone https://github.com/elliott-wave-labs/khensu-core.git   # beside it
cd khensu-apple
xcodegen generate
# optional post-quantum core:
# (cd ../khensu-core && ./scripts/build-xcframework.sh && cd - && scripts/link-core.sh)
open Ptah.xcodeproj
```

In Xcode: select the **Waves** or **Ptah** scheme, your team (`LHS49D8RYY` for Elliott Wave LLC, or your own), a plugged-in iPhone, then Run. Automatic signing is enough for a personal device.

### Archive for App Store Connect

```sh
scripts/archive-ptah.sh    # khėnsu.ñü → ~/Desktop/khensu-ptah-submit/
scripts/archive-waves.sh   # nu.waves → ~/Desktop/khensu-waves-submit/
```

Each writes an `.xcarchive` and, when export succeeds, an `.ipa` beside it. Open the archive in Xcode Organizer → Distribute App → App Store Connect, or export with the matching `ExportOptions-AppStore.plist`. Upload needs an App Store Connect API key (`AuthKey_*.p8`) or a signed-in Xcode account.

## Licences

AGPL-3.0 with the App Store exception in [`APPSTORE-EXCEPTION.md`](../APPSTORE-EXCEPTION.md). Specs and the rest of the stack: [OPEN-SOURCE.md](https://github.com/elliott-wave-labs/khensu-specs/blob/main/OPEN-SOURCE.md).
