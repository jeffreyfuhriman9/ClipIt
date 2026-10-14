# ClipIt

This repository contains the ClipIt product family. Each platform is kept in its
own folder so it can be opened, built, and deployed independently.

```text
.
├── ios/       # Native iOS app and Xcode project
├── android/   # Reserved for the future Android app
├── website/   # Express/TypeScript storefront
└── Firmware/  # ClipIt Button firmware
```

## Open and run each project

- **iOS:** Open `ios/ClipIt.xcodeproj` in Xcode.
- **Website:** Open `website/` in VS Code. Run `pnpm dev` from that folder.
- **Android:** This folder is intentionally empty until the Android project begins.
- **Firmware:** Follow the instructions inside `Firmware/`.

Each subproject keeps its own setup instructions and dependencies. Do not commit
secrets such as `website/.env` or iOS `Secrets.plist`.
