# Willo App Review

**Date:** 2026-02-15
**Reviewer:** Claude (automated code review)
**Scope:** Full codebase review — architecture, rendering, networking, UI, FFI bridge

---

## Executive Summary

Willo is a well-architected iPad terminal app with a clean layered design: Metal rendering, Ghostty VT parsing via Zig FFI, SSH/Mosh transports, and SwiftUI views. The codebase demonstrates strong fundamentals — chunky FFI design, proper actor isolation patterns, and thoughtful session management.

However, the review identified **5 critical issues**, **12 high-severity issues**, and numerous moderate improvements. The most urgent concerns are security-related (accept-all SSH host keys, plaintext password storage) and a struct layout mismatch in the Zig-Swift bridge that causes memory corruption.

### Issue Summary

| Severity | Count | Categories |
|----------|-------|------------|
| **CRITICAL** | 5 | SSH host key bypass, plaintext passwords, struct mismatch, MoshTransport memory leak, credential logging |
| **HIGH** | 12 | Buffer management, deadlock risks, file descriptor leaks, missing auth, incomplete error handling |
| **MEDIUM** | 18 | Performance, code duplication, missing reconnection, magic numbers, view lifecycle |
| **LOW** | 8 | Maintainability, accessibility, cosmetic |

---

## 1. Security Issues

### 1.1 CRITICAL: Accept-All SSH Host Key Validation
**File:** `Sources/Transport/NIOSSHTransport.swift:488-496`

```swift
final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // TODO: Implement proper host key validation with known_hosts
        validationCompletePromise.succeed(())
    }
}
```

**Impact:** Complete man-in-the-middle vulnerability. Any attacker on the network can intercept SSH connections and capture credentials. This undermines the entire security model.

**Fix:** Implement known_hosts file storage using Keychain or app sandbox. On first connect, show host key fingerprint for user verification (TOFU model). On subsequent connects, verify against stored key.

### 1.2 CRITICAL: Plaintext Password Storage
**File:** `Sources/Models/ServerProfile.swift:48`

```swift
case password(String)  // TODO: move to Keychain in production
```

Passwords are stored as plain `String` in `ServerProfile`, which is persisted via `UserDefaults`. This means credentials are:
- Readable by any process with UserDefaults access
- Included in device backups (unless excluded)
- Visible in iCloud sync payloads
- Exposed in memory dumps

**Fix:** Use iOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Store only a Keychain reference in the profile model.

### 1.3 CRITICAL: Credential Logging
**File:** `Sources/Transport/NIOSSHTransport.swift:160-161, 220, 470`

```swift
print("[SSH] Connecting to \(config.host):\(config.port) as \(config.username)")
print("[SSH] Auth method: \(config.authMethod)")
print("[SSH Auth] Username: \(username), password length: \(password.count)")
```

**File:** `Sources/Transport/MoshTransport.swift:278-282`

```swift
print("[Mosh] key length: \(moshKey.count)")
```

Auth methods, password lengths, and Mosh key information are logged to system console. These persist to device syslog, Console.app, and potentially enterprise MDM logging.

**Fix:** Remove all credential-adjacent logging. Use structured logging with redaction for debug builds only.

### 1.4 HIGH: Incomplete SSH Public Key Authentication
**File:** `Sources/Transport/NIOSSHTransport.swift:499-530`

Public key authentication is declared but not implemented. The `PublicKeyAuthDelegate` accepts key data but never parses it, silently falling back to password auth. Similarly, `DefaultKeyAuthDelegate` (line 532-548) for agent auth is a no-op.

**Impact:** Users who configure key-based auth believe they're using it, but passwords are sent instead.

### 1.5 HIGH: No Password Memory Sanitization
**File:** `Sources/Transport/NIOSSHTransport.swift:256-263`

Passwords are stored as Swift `String` objects which are immutable and not zeroed after use. The password survives in memory indefinitely until garbage collected.

---

## 2. Bridge Layer Issues

### 2.1 CRITICAL: TerminalModes Struct Layout Mismatch
**File:** `Sources/Bridging/WilloTerminal.swift:97` vs `Sources/Bridging/willo_bridge.h:66-76`

The C header defines `WilloTerminalModes` with 8 boolean fields + 7 bytes padding. The Swift wrapper adds a 9th field `synchronizedOutput` that reads from the padding region:

```swift
// Swift reads this — but it doesn't exist in the C struct!
self.synchronizedOutput = cModes.synchronized_output
```

This field is then used in `WilloTerminalView.swift:456, 476` to control rendering behavior:

```swift
if modes.synchronizedOutput {
    scheduleSyncFallbackRender()
}
```

**Impact:** Reads uninitialized/random bytes as a boolean. The `synchronizedOutput` mode will randomly appear enabled or disabled, causing rendering glitches.

**Fix:** Either add `bool synchronized_output;` to the C struct in `willo_bridge.h` (and implement in Zig), or remove the field from the Swift wrapper.

### 2.2 HIGH: No Bounds Checking on Terminal Resize
**File:** `Sources/Renderer/WilloTerminalView.swift:508-514`

`resizeGrid(rows:cols:)` accepts arbitrary `Int` values with no validation. A malformed value could trigger a buffer allocation of `rows * cols * 16` bytes.

**Fix:** Add bounds checking:
```swift
guard (1...500).contains(rows), (1...500).contains(cols) else { return }
```

### 2.3 MEDIUM: No Error Return from willo_term_new()
**File:** `Sources/Bridging/WilloTerminal.swift:145-157`

If `willo_term_new()` returns NULL (allocation failure), the Swift wrapper silently continues with a nil handle. All subsequent operations are no-ops via guard clauses, providing no feedback.

### 2.4 MEDIUM: No Error Return from willo_term_feed()
**File:** `Sources/Bridging/willo_bridge.h:108`

The feed function returns `void`, providing no feedback about parse errors, malformed UTF-8, or truncation.

---

## 3. Metal Rendering Issues

### 3.1 HIGH: Vertex Buffer Allocated Every Frame
**File:** `Sources/Renderer/WilloTerminalView.swift:818-831`

A new `MTLBuffer` is created every time the vertex count exceeds the previous buffer size. For an 80×24 grid, this generates 11,520 vertices per frame (6 per cell). No buffer pooling or reuse strategy exists.

**Fix:** Pre-allocate a vertex buffer sized to maximum expected grid dimensions. Reuse across frames.

### 3.2 HIGH: Missing GPU Synchronization
**File:** `Sources/Renderer/WilloTerminalView.swift:833-855`

After `commandBuffer.commit()`, the dirty flag is cleared immediately — before the GPU finishes reading the shared buffers. If new data arrives before the GPU completes, the next `feed()` call could modify buffers being read.

**Fix:** Clear the dirty flag in `commandBuffer.addCompletedHandler()`.

### 3.3 HIGH: Thumbnail Capture Allocates ~90MB
**File:** `Sources/Renderer/WilloTerminalView.swift:1269-1351`

`captureSnapshot()` reads the full-resolution drawable texture into a CPU-side `[UInt8]` array. On iPad Pro 13" Retina, this is ~90MB. The data is then scaled down to a thumbnail.

**Fix:** Use a Metal compute shader or `MTLBlitCommandEncoder` to downsample on GPU before readback.

### 3.4 MEDIUM: Glyph Atlas Has No LRU Eviction
**File:** `Sources/Renderer/GlyphAtlas.swift:314-340`

When the atlas fills up, `resetAtlas()` clears everything and repopulates only ASCII. Any cached CJK, emoji, or extended Unicode glyphs are lost, causing a rendering stall as they're re-rasterized.

**Fix:** Implement true LRU eviction, or use a two-tier atlas (fast ASCII + larger extended).

### 3.5 MEDIUM: Glyph Padding Insufficient for Linear Filtering
**File:** `Sources/Renderer/GlyphAtlas.swift:54` and `Sources/Renderer/TerminalShaders.metal:73-76`

Only 1px padding between glyphs, but the fragment shader uses `linear` filtering which samples a 2×2 quad. This can cause glyph bleeding at edges.

**Fix:** Increase padding to 2-3 pixels, or switch to `nearest` sampling for pixel-perfect terminal rendering.

### 3.6 MEDIUM: Frame Coalescing Race Condition
**File:** `Sources/Renderer/WilloTerminalView.swift:588-614`

`setNeedsDisplay()` uses `hasPendingRender` flag without thread synchronization. Multiple threads calling this concurrently can schedule duplicate renders or lose updates entirely.

### 3.7 MEDIUM: Excessive Glyph Lookups Per Frame
**File:** `Sources/Renderer/WilloTerminalView.swift:760-773`

Every cell performs a dictionary lookup in the glyph atlas every frame — 1,920 lookups per frame for an 80×24 grid at 120fps = 230,400 lookups/second. These could be cached in the cell data.

### 3.8 MEDIUM: Missing Shader Compilation Validation
**File:** `Sources/Renderer/WilloTerminalView.swift:335-406`

`library.makeFunction(name:)` can return nil if shaders fail to compile, but the return value isn't checked. Pipeline setup fails silently.

---

## 4. Transport & Networking Issues

### 4.1 CRITICAL: MoshTransport Memory Leak on Reconnect
**File:** `Sources/Transport/MoshTransport.swift:221-235`

```swift
let selfPtr = Unmanaged.passRetained(self).toOpaque()  // RETAIN
pthread_create(&thread, nil, { context -> ... }, selfPtr)
pthread_detach(thread)  // No cleanup notification
```

`passRetained(self)` creates a strong reference released only when `runMosh()` exits. If Mosh never connects or the transport is deallocated during connection, the reference leaks. Multiple reconnection attempts compound the leak.

### 4.2 HIGH: Double Deallocation of Window Size Pointer
**File:** `Sources/Transport/MoshTransport.swift:187-190, 305-307, 325-327`

`windowSizePtr` is deallocated in three places: `deinit`, `runMosh()`, and `disconnect()`. With no synchronization, concurrent calls can double-free the pointer.

**Fix:** Use a single deallocation site behind a lock, or use `Optional` semantics (set to nil after dealloc).

### 4.3 HIGH: File Descriptor Leak in MoshTransport
**File:** `Sources/Transport/MoshTransport.swift:334-339`

`closePipes()` closes raw file descriptors, but `fdopen()` in `runMosh()` creates `FILE*` wrappers that also close the underlying FD via `fclose()`. The race between `disconnect()` closing pipes and `runMosh()` closing FILE handles can double-close FDs.

### 4.4 HIGH: Callback Deadlock in SSHDataCallbackState
**File:** `Sources/Transport/NIOSSHTransport.swift:24-79`

User callbacks are invoked while holding an `NSLock`. If the callback tries to send data (calling back into the transport), it will attempt to acquire the same lock → deadlock.

```swift
func setPrimaryCallback(_ cb: @escaping (Data) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    for data in pendingData {
        cb(data)  // ← Called under lock!
    }
}
```

**Fix:** Copy pending data, release lock, then invoke callbacks.

### 4.5 MEDIUM: No Automatic Reconnection
**File:** `Sources/Session/SessionManager.swift:76-100`

`ExponentialBackoff` is defined but never used. `NetworkMonitor` is created but never integrated with transports. When the network drops, connections fail without retry.

**Fix:** Wire `NetworkMonitor.isConnected` changes to trigger reconnection via `ExponentialBackoff`.

### 4.6 MEDIUM: Mosh Connection Timeout Too Short
**File:** `Sources/Transport/MoshTransport.swift:194-249`

Only 100ms wait after spawning `mosh_main` before marking as `.connected`. This is not enough time for UDP handshake, especially on slow networks. The transport reports "connected" before any server contact.

### 4.7 MEDIUM: SSH Timeout Ignores Configuration
**File:** `Sources/Transport/NIOSSHTransport.swift:243`

Hardcoded `.connectTimeout(.seconds(10))` ignores `config.connectionTimeout` (defaults to 30s). Mobile users on high-latency networks fail unnecessarily.

### 4.8 MEDIUM: Silent Channel Error Handling
**File:** `Sources/Transport/NIOSSHTransport.swift:573-576`

```swift
func errorCaught(context: ChannelHandlerContext, error: Error) {
    print("[SSH] Shell error: \(error)")
    context.close(promise: nil)  // Silent close, transport stays "connected"
}
```

Channel errors close the NIO channel but don't update transport state. The session appears connected but is dead.

---

## 5. Architecture & State Management

### 5.1 MEDIUM: ZellijBridge Coupled to NIOSSHTransport
**File:** `Sources/Bridge/ZellijBridge.swift:87`

`startBridge()` takes `NIOSSHTransport` directly instead of the `Transport` protocol. This prevents using bridges with Mosh transport.

**Fix:** Accept `any Transport` or extract a bridge-specific protocol.

### 5.2 MEDIUM: Cloud Sync Merge Logic Duplicated
**Files:** `Sources/App/WilloApp.swift:97-127` and `Sources/Store/SessionStore.swift:390-421`

Nearly identical timestamp-based merge logic exists in two places (~35 lines each).

**Fix:** Extract generic merge function into `CloudSyncManager`.

### 5.3 MEDIUM: Excessive @EnvironmentObject Usage
41 `@EnvironmentObject` references across views for `sessionStore`, `sessionManager`, `appearanceSettings`, and `layoutStore`. Views are tightly coupled to multiple managers.

**Fix:** Create a facade or coordinator to reduce injection surface.

### 5.4 MEDIUM: DataCallbackState Duplicated
**Files:** `NIOSSHTransport.swift:23-79` and `MoshTransport.swift:21-87`

~60 lines of identical thread-safe callback state management code.

**Fix:** Extract shared `CallbackState<T>` generic utility.

### 5.5 MEDIUM: NetworkMonitor Singleton Misuse
**File:** `Sources/Views/TerminalWorkspaceView.swift:19`

```swift
@StateObject private var networkMonitor = NetworkMonitor.shared
```

`@StateObject` creates a new instance; wrapping a singleton in it is semantically wrong. Use `@ObservedObject` or direct access.

---

## 6. UI/UX Issues

### 6.1 MEDIUM: Connection Error Never Displayed
**File:** `Sources/Views/TerminalWorkspaceView.swift:18`

```swift
@State private var connectionError: Error?
```

Declared but never shown to the user. Transport errors are swallowed via `try?` throughout the view.

### 6.2 MEDIUM: SessionGridCard Forces Full Re-render
**File:** `Sources/Views/SessionContainerView.swift:799`

```swift
.id(refreshID)
.onReceive(sessionStore.thumbnailManager.$thumbnails) { thumbnails in
    if thumbnails[session.id] != nil {
        refreshID = UUID()  // Recreates entire view tree
    }
}
```

Using `.id()` to force refresh destroys and recreates the entire view subtree. Use `@Published` image property instead.

### 6.3 LOW: Magic Numbers Throughout Views
20+ hardcoded spacing values, delays, and thresholds across view files. Examples:
- `height: bounds.height - 60` (TerminalWorkspaceView.swift:408)
- `threshold: CGFloat = 60` (SessionContainerView.swift:133)
- `300_000_000` nanoseconds (TerminalWorkspaceView.swift:231)

**Fix:** Extract to named constants in a design system.

### 6.4 LOW: Keyboard Shortcut Conflicts
**File:** `Sources/Views/SessionContainerView.swift:299-327`

`Cmd+Shift+[/]` for zellij tab switching may conflict with iPad system shortcuts.

### 6.5 LOW: No Keyboard Shortcut Help Overlay
Users have no way to discover available shortcuts. Consider adding a help overlay triggered by `Cmd+/` or long-press `Cmd`.

---

## 7. Code Quality

### 7.1 Heavy Use of `try?` Error Suppression
121 occurrences of error suppression across the codebase. Many suppress errors that should be reported:
- `SessionStore.closeSession()` line 276: disconnect errors swallowed
- `TerminalWorkspaceView.swift:90`: transport send errors swallowed
- `NIOSSHTransport.swift:327-340`: channel close errors swallowed

### 7.2 258 `print()` Statements
No structured logging. Debug output goes to system console in production. Should use `os.Logger` with appropriate log levels.

### 7.3 Incomplete Features (9 TODOs)
| Location | Issue |
|----------|-------|
| `NIOSSHTransport.swift:494` | Host key validation |
| `NIOSSHTransport.swift:516,526,546` | SSH key auth (3 TODOs) |
| `ServerProfile.swift:48` | Keychain migration |
| `GhosttyBridge.swift:21` | Remove stubs |
| `WilloTerminalView.swift:1128` | Text selection |
| `WilloTerminalView.swift:1256` | CJK IME support |
| `TUIAppStore.swift:117` | Remote app detection |

---

## 8. Positive Patterns

The codebase has many strengths worth highlighting:

- **Clean architecture:** Well-separated layers with clear responsibilities
- **Chunky FFI:** Single bulk render() call instead of per-cell bridge crossings
- **Actor isolation:** Proper use of Swift actors for transport state (SSHTransportState, MoshTransportState)
- **Weak references:** Correct cycle-breaking in SessionStore ↔ SessionManager
- **ActivityDetector:** Intelligent session state analysis for TUI detection
- **16-byte aligned RenderCell:** Proper Metal buffer alignment with explicit padding
- **Ed25519 key management:** SSHKeyManager uses CryptoKit + Keychain correctly
- **Minimal dependencies:** Only one external dependency (NIOSSH); everything else is internal

---

## 9. Recommended Priority Order

### Immediate (Pre-release Blockers)
1. Implement SSH host key validation (TOFU model)
2. Move passwords to Keychain
3. Fix `synchronizedOutput` struct mismatch in bridge
4. Remove credential logging
5. Fix MoshTransport memory leak / double-free

### High Priority (Next Sprint)
6. Fix callback deadlock in SSHDataCallbackState
7. Implement SSH public key authentication
8. Add GPU synchronization for dirty flag
9. Integrate NetworkMonitor with transports for auto-reconnect
10. Fix Mosh connection handshake (don't mark connected after 100ms)
11. Wire up connection error display in UI

### Medium Priority (Next 2 Sprints)
12. Implement vertex buffer pooling
13. Add glyph atlas LRU eviction
14. Extract ZellijBridge transport protocol
15. Centralize cloud sync merge logic
16. Replace `print()` with `os.Logger`
17. Add bounds checking on terminal resize
18. Fix thumbnail capture memory usage

### Low Priority (Backlog)
19. Extract design constants
20. Add keyboard shortcut help overlay
21. Implement text selection
22. Add CJK IME support
23. Reduce @EnvironmentObject surface area

---

## Codebase Statistics

| Metric | Value |
|--------|-------|
| Swift source files | 51 |
| Lines of code | ~18,500 |
| `print()` calls | 258 |
| `try?` suppressions | 121 |
| `@EnvironmentObject` refs | 41 |
| TODO/FIXME comments | 9 |
| Largest file | WilloTerminalView.swift (1,386 lines) |
| External dependencies | 1 (NIOSSH) |
