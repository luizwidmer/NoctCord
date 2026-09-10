# App Store builds

The Swift package remains the source of the app modules. `project.yml` defines an Xcode application wrapper for signing, archives, StoreKit testing, and App Store Connect upload. Regenerate it with XcodeGen 2.46 or later:

```sh
xcodegen generate
open NoctCord.xcodeproj
```

Use scheme **NoctCord**, choose **Any Mac**, and archive. In Organizer, use Distribute App → App Store Connect. Xcode can create the app record on the first upload. The configured team is `9MY7SXN56X`; the bundle ID remains `org.noctweave.noctcord`.

`SupportTips.storekit` configures simulated, one-time tips for local Debug runs. App Store builds load their actual products and localized prices from Apple. Create Small Tip / Medium Tip / Large Tip as consumables, with US base prices $1.99 / $4.99 / $9.99. Their exact IDs are in the app Info.plist. No tip unlocks features. Submit the first consumable products with an app version. Review links use the configured Apple ID or the verified production App Store app transaction.

Keep marketing/build versions aligned in the plist and Xcode settings. Preserve the existing sandbox entitlements when distributing.

WebRTC is pinned to the M152 source revision and binary checksum. The archive post-action downloads its official dSYMs, verifies SHA-256 and every embedded Mach-O UUID, and attaches only the macOS symbols. To verify an archive independently before upload:

```sh
python3 Scripts/prepare-app-store-symbols.py --archive "/path/to/Noct Cord.xcarchive"
```
