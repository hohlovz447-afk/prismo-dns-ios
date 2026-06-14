<div align="right">

[🇷🇺 Русский](README.md) · **🇬🇧 English**

</div>

# Prismo DNS

iOS client Prismo DNS — a DNS-tunneling VPN for extreme-censorship networks.

It exposes a local SOCKS5 proxy at `127.0.0.1:41080` and keeps the tunnel running while you switch to another app (Shadowrocket, Happ, etc.) that runs the proxy.
The app does **not** create an iOS VPN profile, since it is unsigned.

## Repository layout

```
prismo-dns-ios/
├── apple/                            # Xcode / SwiftPM project
│   ├── Package.swift                 # PrismoKit shared library
│   ├── project.yml                   # XcodeGen project definition
│   ├── Frameworks/                   # Mobile.xcframework lands here
│   ├── Scripts/
│   │   ├── build-xcframework.sh         # gomobile bind → Mobile.xcframework
│   │   ├── build-ios-unsigned-local-ipa.sh
│   │   ├── prepare-xcode.sh             # xcodegen wrapper
│   │   └── generate-icon.py             # AppIcon generator (Pillow)
│   ├── Sources/
│   │   ├── PrismoApp/            # iOS app target
│   │   │   ├── Assets.xcassets/AppIcon.appiconset/
│   │   │   ├── Info.plist            # UIBackgroundModes=[audio]
│   │   │   └── PrismoApp.swift
│   │   └── PrismoKit/            # Shared SwiftPM library
│   │       ├── Models/               # ConnectionProfile, ClientStatus
│   │       ├── Services/             # TunnelEngine, BackgroundRuntimeKeeper, …
│   │       ├── ViewModels/           # ClientViewModel
│   │       ├── Views/                # ContentView, ImportProfileSheet, …
│   │       └── Resources/{en,ru}.lproj/Localizable.strings
│   └── Tests/PrismoKitTests/
└── engine/                           # Go DNS-tunnel core
    ├── go.mod                        # adds golang.org/x/mobile dep
    └── mobile/                       # gomobile-bindable wrapper package
        ├── mobile.go                 #   Start/Stop/IsRunning/SetLogWriter
        └── stdout_pump.go            #   forwards stdout → LogWriter
```

## Prerequisites

- macOS 14 + Xcode 16 (the iOS toolchain ships with Xcode)
- [Homebrew](https://brew.sh)
- `brew install go xcodegen`
- `go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init`
- Python 3 with Pillow (`python3 -m pip install --user pillow`) — only needed if you want to regenerate the AppIcon

## Build

```bash
# 1. Build the Go xcframework
apple/Scripts/build-xcframework.sh

# 2. Generate the Xcode project
apple/Scripts/prepare-xcode.sh

# 3. Build an unsigned IPA
apple/Scripts/build-ios-unsigned-local-ipa.sh
#   → apple/.build/ios-unsigned-local/PrismoDNS-unsigned.ipa
```

The IPA is unsigned. Sign and install it on a device using:

- **[Sideloadly](https://sideloadly.io)** — drop the IPA in, sign with your Apple ID, install via USB.
- **AltStore / SideStore** — install on-device, no Mac needed for re-signing after the first push.

Enable **Settings → Privacy & Security → Developer Mode** on the iPhone before the first install.

## Usage

1. Launch Prismo DNS and tap **Import**.
2. Enter the delegated domain from your server (the same value as the NS record, e.g. `v.example.com`).
3. Enter the shared encryption key (must match the server-side key).
4. Tap **Import**, then the connect (power) button. **Encryption Type** must match the server's server_config.toml **DATA_ENCRYPTION_METHOD** (XOR by default in both)
5. The SOCKS5 proxy comes up at `127.0.0.1:41080`. Open Shadowrocket / Happ / etc. and add a SOCKS5 proxy pointing at that address.
6. Prismo DNS keeps the listener alive while you switch to other apps. Killing the app from the app switcher stops the tunnel.
