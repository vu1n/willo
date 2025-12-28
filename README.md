# Willo

**Fast, resilient iPad terminal for remote development.**

Willo is a native iPad terminal app optimized for keyboard-driven workflows, spotty connections (via Mosh), and server-side session persistence (via zellij/tmux). It uses Ghostty's VT parser for accurate terminal emulation and Metal for high-performance rendering.

## Features

### Core Terminal
- **Metal-accelerated rendering** with custom glyph atlas
- **Ghostty VT parser** (Zig) for accurate ANSI/xterm emulation
- **JetBrains Mono Nerd Font** with full icon support
- **Bracketed paste** and **mouse wheel scrolling** for TUI apps

### Connection Resilience
- **Mosh support** for roaming/spotty connections (UDP-based)
- **SSH fallback** via NIOSSH when Mosh unavailable
- **Auto-reconnect** with exponential backoff
- **Server-side persistence** via zellij/tmux sessions

### Session Management
- **Multi-session tabs** with swipe gestures
- **Session thumbnails** for visual context
- **Keyboard shortcuts** (Cmd+1-9, Cmd+N, Cmd+W)
- **Named sessions** (zellij-style: `adjective-noun`)

### TUI App Gallery
- **Curated catalog** of 17+ popular TUI apps
- **One-tap launch** from terminal status bar
- **Install commands** via Homebrew
- Categories: Dev Tools, Monitoring, Files, Productivity

### Server Profiles
- **Connection testing** before saving
- **SSH key generation** (Ed25519) with Keychain storage
- **One-tap key installation** (ssh-copy-id equivalent)
- **Mosh preference** per profile

## Architecture

```
willo/
├── apps/ios/Willo/          # iOS app (SwiftUI + Metal)
│   └── Sources/
│       ├── App/             # WilloApp, ContentView
│       ├── Bridging/        # C/Swift bridge (willo_bridge.h, WilloTerminal.swift)
│       ├── Renderer/        # Metal renderer (GlyphAtlas, WilloTerminalView)
│       ├── Transport/       # SSH/Mosh transports (NIOSSH, MoshTransport)
│       ├── Session/         # Session management
│       ├── Store/           # State (SessionStore, TUIAppStore, LayoutStore)
│       ├── Models/          # Data models (ServerProfile, WilloSession)
│       ├── Services/        # SSHKeyManager
│       └── Views/           # SwiftUI views
│
├── vendor/ghostty/          # Ghostty VT parser (Zig submodule)
│   └── src/
│       ├── willo_shim.zig   # Willo-specific wrapper
│       └── lib_willo.zig    # Library exports
│
├── build/                   # Build artifacts
│   ├── libwillo/            # Compiled Zig libraries
│   └── xcframeworks/        # iOS frameworks
│
└── vendor/build-mosh/       # Mosh iOS build
```

## Building

### Prerequisites
- Xcode 15.4+ with iOS 17 SDK
- Zig 0.14+ (for Ghostty VT parser)
- macOS 14+ (Sonoma)

### Build Zig Library
```bash
cd vendor/ghostty

# Build for iOS device
zig build lib-willo -Dtarget=aarch64-ios -Doptimize=ReleaseFast -Dsimd=false

# Build for iOS simulator
zig build lib-willo -Dtarget=aarch64-ios-simulator -Doptimize=ReleaseFast -Dsimd=false
```

### Build iOS App
```bash
cd apps/ios
open Willo.xcodeproj
# Build with Xcode (Cmd+B)
```

Or via command line:
```bash
xcodebuild -scheme Willo -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build
```

## Key Technologies

| Component | Technology | Purpose |
|-----------|------------|---------|
| VT Parser | Ghostty (Zig) | ANSI/xterm terminal emulation |
| Renderer | Metal + CoreText | GPU-accelerated text rendering |
| SSH | NIOSSH | Pure Swift SSH client |
| Mosh | libmosh | UDP-based roaming transport |
| UI | SwiftUI | Modern declarative UI |
| Storage | Keychain | Secure SSH key storage |

## Dependencies

### Swift Packages (via SPM)
- `swift-nio-ssh` - SSH protocol implementation

### Native Frameworks (XCFramework)
- `willo.xcframework` - Ghostty VT parser (from Zig)
- `mosh.xcframework` - Mosh client library
- `Protobuf_C_.xcframework` - Mosh protocol buffers

## Development

### Issue Tracking
This project uses [Beads](https://github.com/steveyegge/beads) for AI-native issue tracking:

```bash
bd list              # View all issues
bd create "..."      # Create issue
bd show <id>         # View issue details
bd update <id> --status in_progress
bd close <id>
bd sync              # Sync with git
```

### Key Files for New Contributors

| File | Purpose |
|------|---------|
| `willo_bridge.h` | C API contract between Zig and Swift |
| `WilloTerminal.swift` | Swift wrapper for terminal C API |
| `WilloTerminalView.swift` | Metal renderer + input handling |
| `NIOSSHTransport.swift` | SSH connection implementation |
| `SessionStore.swift` | Session state management |
| `ServerProfile.swift` | Connection profile model |

## License

Proprietary - All rights reserved.

## Contributing

This is a private project. See CLAUDE.md for AI agent contribution guidelines.
