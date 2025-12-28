# CLAUDE.md - AI Agent Context for Willo

This document provides all context needed for AI agents to work effectively on the Willo codebase.

## Project Overview

**Willo** is a native iPad terminal app for remote development. Key pillars:
1. **Fast rendering** - Metal + Ghostty VT parser
2. **Connection resilience** - Mosh + SSH with auto-reconnect
3. **Session persistence** - Server-side zellij/tmux
4. **Keyboard-first UX** - Full hardware keyboard support

## Repository Structure

```
willo/
├── apps/ios/Willo/              # Main iOS application
│   ├── Package.swift            # SPM manifest (dependencies)
│   ├── Willo.xcodeproj/         # Xcode project
│   ├── Sources/                 # Swift source code
│   │   ├── App/                 # App entry point, ContentView
│   │   ├── Bridging/            # Zig ↔ Swift bridge
│   │   │   ├── willo_bridge.h   # C API header (THE CONTRACT)
│   │   │   └── WilloTerminal.swift  # Swift wrapper
│   │   ├── Renderer/            # Metal terminal rendering
│   │   │   ├── GlyphAtlas.swift     # Font texture atlas
│   │   │   ├── WilloTerminalView.swift  # MTKView subclass
│   │   │   └── TerminalShaders.metal    # GPU shaders
│   │   ├── Transport/           # Network transports
│   │   │   ├── TransportProtocol.swift  # Abstract transport
│   │   │   ├── NIOSSHTransport.swift    # SSH via NIOSSH
│   │   │   ├── MoshTransport.swift      # Mosh wrapper
│   │   │   └── SSHTransport.swift       # Alternative SSH
│   │   ├── Session/             # Session lifecycle
│   │   │   ├── SessionManager.swift     # Manages TerminalSession
│   │   │   ├── ActivityDetector.swift   # Detect terminal activity
│   │   │   ├── NetworkMonitor.swift     # Connectivity monitoring
│   │   │   └── ExponentialBackoff.swift # Retry logic
│   │   ├── Store/               # State management
│   │   │   ├── SessionStore.swift       # Active sessions
│   │   │   ├── TUIAppStore.swift        # TUI app catalog
│   │   │   ├── LayoutStore.swift        # Zellij layouts
│   │   │   ├── ThumbnailManager.swift   # Session screenshots
│   │   │   └── CloudSyncManager.swift   # iCloud sync
│   │   ├── Models/              # Data structures
│   │   │   ├── ServerProfile.swift      # Connection config
│   │   │   ├── WilloSession.swift       # Session state
│   │   │   ├── Workspace.swift          # Tab workspace
│   │   │   └── AppearanceSettings.swift # UI preferences
│   │   ├── Services/            # Utilities
│   │   │   └── SSHKeyManager.swift      # Ed25519 key management
│   │   ├── Views/               # SwiftUI views
│   │   │   ├── WelcomeView.swift        # Home screen
│   │   │   ├── ServerProfilesView.swift # Profile management
│   │   │   ├── SessionContainerView.swift   # Tab container
│   │   │   ├── TerminalWorkspaceView.swift  # Terminal + status bar
│   │   │   ├── CommandPaletteView.swift     # Cmd+K palette
│   │   │   └── TUIGallery/              # TUI app browser
│   │   └── Resources/           # Bundled assets
│   │       └── Fonts/           # JetBrains Mono Nerd Font
│   └── Frameworks/              # Pre-built xcframeworks
│       ├── willo.xcframework    # Ghostty VT (from Zig)
│       ├── mosh.xcframework     # Mosh client
│       └── Protobuf_C_.xcframework
│
├── vendor/ghostty/              # Ghostty (git submodule)
│   ├── src/
│   │   ├── willo_shim.zig       # Willo-specific API wrapper
│   │   ├── lib_willo.zig        # Library entry point
│   │   └── terminal/            # Core terminal emulation
│   └── build.zig                # Zig build system
│
├── vendor/build-mosh/           # Mosh iOS build (submodule)
├── build/                       # Build outputs
├── .beads/                      # Issue tracking database
└── willo-plan.md                # Original design document
```

## Core Data Flow

```
[SSH/Mosh Data] → Transport → WilloTerminal (Zig) → WilloTerminalView (Metal)
                      ↓
              [Terminal State]
                      ↓
               [Render Cells] → GlyphAtlas → Metal Texture → Screen
```

### Input Flow
```
[Hardware Keyboard] → UIKeyCommand → WilloTerminalView.handleKeyPress()
                                           ↓
                                   [Escape Sequences]
                                           ↓
                                     Transport.send()
                                           ↓
                                     [SSH/Mosh → Server]
```

## Key Interfaces

### C API (willo_bridge.h)
The contract between Zig and Swift. **This is the most important file.**

```c
// Core types
typedef struct WilloRenderCell;      // 16-byte cell for Metal
typedef struct WilloTerminalInfo;    // Terminal state
typedef struct WilloTerminalModes;   // Input modes

// Lifecycle
WilloTerminal* willo_term_new(uint16_t rows, uint16_t cols);
void willo_term_free(WilloTerminal* term);

// Input
void willo_term_feed(WilloTerminal* term, const char* data, size_t len);
void willo_term_resize(WilloTerminal* term, uint16_t rows, uint16_t cols);

// Rendering
void willo_term_get_info(WilloTerminal* term, WilloTerminalInfo* out);
size_t willo_term_render(WilloTerminal* term, WilloRenderCell* buffer, size_t max);
bool willo_term_is_dirty(WilloTerminal* term);
void willo_term_get_modes(WilloTerminal* term, WilloTerminalModes* out);
```

### Transport Protocol
```swift
protocol Transport {
    var state: TransportState { get async }
    func connect() async throws
    func disconnect() async throws
    func send(_ data: Data) async throws
    func resize(cols: UInt16, rows: UInt16) async throws
    var onData: ((Data) -> Void)? { get set }
}
```

### Session Model
```swift
struct WilloSession: Identifiable {
    let id: UUID
    let name: String              // e.g., "bold-river"
    let serverProfile: ServerProfile
    var connectionState: ConnectionState
    var color: SessionColor
    var layoutId: String?         // Zellij layout
}
```

## Building & Development

### Prerequisites
```bash
# Required tools
brew install zig           # Zig 0.14+
xcode-select --install     # Xcode command line tools
```

### Rebuild Zig Library
When changing `willo_shim.zig` or `lib_willo.zig`:

```bash
cd vendor/ghostty

# iOS device (arm64)
zig build lib-willo -Dtarget=aarch64-ios -Doptimize=ReleaseFast -Dsimd=false

# iOS simulator (arm64)
zig build lib-willo -Dtarget=aarch64-ios-simulator -Doptimize=ReleaseFast -Dsimd=false
```

**Important**: Use `-Dsimd=false` to avoid C++ cross-compilation issues.

### Create XCFramework
```bash
# Copy libraries
cp zig-out/lib/libwillo.a /path/to/ios-arm64/
cp zig-out/lib/libwillo.a /path/to/ios-arm64-simulator/

# Create framework
xcodebuild -create-xcframework \
    -library ios-arm64/libwillo.a -headers ios-arm64/Headers \
    -library ios-arm64-simulator/libwillo.a -headers ios-arm64-simulator/Headers \
    -output willo.xcframework
```

### Build iOS App
```bash
cd apps/ios
xcodebuild -scheme Willo -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=18.6' build
```

## Issue Tracking (Beads)

This project uses Beads for AI-native issue tracking:

```bash
bd list                    # List all issues
bd ready                   # Show unblocked issues
bd create --title="..." --type=task --priority=2
bd update <id> --status=in_progress
bd close <id>
bd sync                    # Sync with git (run at session end)
```

**Session close protocol**:
```bash
git status                 # Check changes
git add <files>            # Stage code
bd sync                    # Commit beads
git commit -m "..."        # Commit code
bd sync                    # Sync beads again
git push                   # Push to remote
```

## Common Tasks

### Add a new terminal mode
1. Add field to `WilloTerminalModes` in `willo_bridge.h`
2. Populate it in `willo_term_get_modes()` in `willo_shim.zig`
3. Add Swift field in `WilloTerminal.swift` → `TerminalModes`
4. Use in `WilloTerminalView.swift` for input handling
5. Rebuild Zig library and xcframework

### Add a TUI app to gallery
Edit `TUIAppStore.swift`:
```swift
TUIApp(
    id: "app-id",
    name: "App Name",
    description: "What it does",
    category: .devTools,  // or .monitoring, .files, .productivity
    installCommand: "brew install app-name",
    launchCommand: "app-name",
    checkCommand: "which app-name",
    website: "https://...",
    iconName: "sf.symbol.name"
)
```

### Add a keyboard shortcut
In `SessionContainerView.swift`:
```swift
Button("") {
    // Action
}
.keyboardShortcut("x", modifiers: .command)
.hidden()
```

### Test SSH connection programmatically
```swift
let config = TransportConfig(
    host: "hostname",
    port: 22,
    username: "user",
    authMethod: .password("pass"),
    terminalCols: 80,
    terminalRows: 24
)
let transport = NIOSSHTransport(config: config)
try await transport.connect()
```

## Design Principles

1. **Server-side session persistence** - Always use zellij/tmux. The iPad is a view.
2. **Fail gracefully** - Mosh unavailable? Fall back to SSH. No zellij? Raw shell.
3. **Chunky FFI** - Bulk operations over the C bridge, not per-cell calls.
4. **Metal for rendering** - CoreText for shaping, Metal for drawing.
5. **Keyboard first** - Every action has a keyboard shortcut.

## Known Limitations

- **No inline images** - Terminal images not yet supported
- **No hyperlinks** - OSC 8 parsing pending
- **No scrollback search** - Find in terminal not implemented
- **Single device** - No multi-device session sync

## Files to Read First

1. `willo_bridge.h` - The C API contract
2. `WilloTerminal.swift` - Swift terminal wrapper
3. `WilloTerminalView.swift` - Metal renderer
4. `SessionContainerView.swift` - Session UI
5. `NIOSSHTransport.swift` - SSH implementation

## Useful Grep Patterns

```bash
# Find where terminal modes are used
rg "getModes|TerminalModes" apps/ios

# Find keyboard shortcuts
rg "keyboardShortcut" apps/ios

# Find escape sequence handling
rg "\\\\x1B|\\\\u{1B}" apps/ios

# Find Metal rendering
rg "MTKView|MTLDevice" apps/ios
```

## Contact

This is a private project by @vu1n.
