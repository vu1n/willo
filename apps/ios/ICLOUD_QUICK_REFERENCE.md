# iCloud Sync Quick Reference

Quick reference for developers working with iCloud sync in Willo.

## Usage in Code

### Access the Cloud Sync Manager

```swift
let cloudSync = CloudSyncManager.shared
```

### Check iCloud Availability

```swift
if cloudSync.isAvailable {
    // iCloud is available
} else {
    // User not signed in or iCloud disabled
}
```

### Monitor Sync State

```swift
// In a SwiftUI view
@ObservedObject var cloudSync = CloudSyncManager.shared

var body: some View {
    if cloudSync.syncState == .syncing {
        ProgressView("Syncing...")
    }
}
```

### Force Manual Sync

```swift
cloudSync.forceSynchronize()
```

### Listen for Sync Events

```swift
cloudSync.syncEvents
    .sink { event in
        switch event {
        case .sessionsChanged:
            // Handle session changes
        case .profilesChanged:
            // Handle profile changes
        case .layoutsChanged:
            // Handle layout changes
        }
    }
    .store(in: &cancellables)
```

## How Data Syncs

### Sessions (SessionStore)

```swift
// Creating/modifying a session automatically syncs
sessionStore.createSession(from: profile)
sessionStore.updateSession(sessionId, name: "New Name")

// Sync happens in saveSessions() which calls:
// cloudSync.syncSessions(sessions)
```

### Server Profiles (AppState)

```swift
// Modifying profiles automatically syncs via @Published observer
appState.serverProfiles.append(newProfile)

// Sync happens in saveServerProfiles() which calls:
// cloudSync.syncServerProfiles(serverProfiles)
```

### User Layouts (LayoutStore)

```swift
// Adding/modifying layouts automatically syncs
layoutStore.addLayout(name: "My Layout", kdlContent: kdl)
layoutStore.renameLayout(layoutId, newName: "New Name")

// Sync happens in saveLayouts() which calls:
// cloudSync.syncUserLayouts(userLayouts)
```

## Merge Behavior

### Session Merge
- **Key**: UUID
- **Timestamp**: `lastActivityAt`
- **Rule**: Most recently active wins
- **Preserves**: Local connection state, activity state

### Profile Merge
- **Key**: UUID
- **Timestamp**: `lastConnected`
- **Rule**: Most recently connected wins
- **Preserves**: Local auth method (passwords stay local)

### Layout Merge
- **Key**: UUID
- **Timestamp**: `createdAt`
- **Rule**: Most recently created wins
- **Preserves**: N/A (full layout syncs)

## Common Patterns

### Check Sync Status Before Action

```swift
if cloudSync.syncState == .error(let message) {
    // Show error to user
    showAlert("Sync Error", message: message)
}
```

### Disable Features When iCloud Unavailable

```swift
Button("Share Session") {
    shareSession()
}
.disabled(!cloudSync.isAvailable)
.help(cloudSync.isAvailable ? "Share via iCloud" : "iCloud not available")
```

### Show Last Sync Time

```swift
if let lastSync = cloudSync.lastSyncDate {
    Text("Last synced: \(lastSync.formatted(.relative(presentation: .named)))")
        .foregroundColor(.secondary)
}
```

## Security Best Practices

### ✅ DO
- Sync metadata (names, colors, preferences)
- Sync references (IDs, layout names)
- Sanitize auth methods before sync
- Preserve local passwords during merge

### ❌ DON'T
- Sync passwords directly
- Sync SSH private keys
- Sync terminal output/history
- Sync connection tokens

## Testing

### Simulate External Change

```swift
// On Device A: Modify data
sessionStore.updateSession(id, name: "Updated")

// On Device B: Wait ~5 seconds, then check
// CloudSyncManager will receive notification and merge
```

### Debug Logging

Look for these console messages:

```
[CloudSync] iCloud available - setting up sync
[CloudSync] Synced 5 sessions to iCloud
[CloudSync] External change detected
[SessionStore] Merging 5 sessions from iCloud
```

### Test Without iCloud

```swift
// CloudSyncManager gracefully handles unavailable state
guard isAvailable else { return } // Early exit in all sync methods
```

## Troubleshooting

### Sync Not Working

```swift
// Check availability
print("iCloud available: \(cloudSync.isAvailable)")

// Check state
print("Sync state: \(cloudSync.syncState)")

// Force sync
cloudSync.forceSynchronize()
```

### Data Not Appearing

1. Check both devices use same iCloud account
2. Verify entitlements are configured
3. Check network connectivity
4. Wait 30-60 seconds for initial sync
5. Check console for error messages

### Quota Issues

```swift
// CloudSyncManager will log quota violations
// Check console for:
// [CloudSync] WARNING: iCloud quota exceeded!

// Reduce data size by:
// - Removing old sessions
// - Cleaning up unused layouts
```

## API Reference

### CloudSyncManager Methods

```swift
// Sessions
func syncSessions(_ sessions: [WilloSession])
func loadSessions() -> [SyncableSession]?
func mergeSessions(local: [WilloSession], cloud: [SyncableSession]) -> [WilloSession]

// Server Profiles
func syncServerProfiles(_ profiles: [ServerProfile])
func loadServerProfiles() -> [SyncableServerProfile]?
func mergeServerProfiles(local: [ServerProfile], cloud: [SyncableServerProfile]) -> [ServerProfile]

// User Layouts
func syncUserLayouts(_ layouts: [UserLayout])
func loadUserLayouts() -> [UserLayout]?
func mergeUserLayouts(local: [UserLayout], cloud: [UserLayout]) -> [UserLayout]

// Control
func forceSynchronize()
```

### CloudSyncManager Properties

```swift
@Published var isAvailable: Bool          // iCloud available?
@Published var lastSyncDate: Date?        // Last sync timestamp
@Published var syncState: SyncState       // Current sync state

let syncEvents: PassthroughSubject<SyncEvent, Never>  // Event stream
```

### SyncState Enum

```swift
enum SyncState: Equatable {
    case idle           // Not syncing
    case syncing        // Sync in progress
    case error(String)  // Sync error occurred
}
```

### SyncEvent Enum

```swift
enum SyncEvent {
    case sessionsChanged    // Sessions changed externally
    case profilesChanged    // Profiles changed externally
    case layoutsChanged     // Layouts changed externally
}
```

## File Locations

```
Willo/Sources/Store/
├── CloudSyncManager.swift    # Main sync implementation
├── SessionStore.swift         # Session sync integration
└── LayoutStore.swift          # Layout sync integration

Willo/Sources/App/
└── WilloApp.swift             # Profile sync integration (AppState)

Willo/Sources/Models/
├── WilloSession.swift         # Session models
├── ServerProfile.swift        # Profile models
└── Workspace.swift            # ConnectionState enum
```

## Further Reading

- [ICLOUD_SETUP.md](./ICLOUD_SETUP.md) - Setup instructions
- [IMPLEMENTATION_SUMMARY.md](./IMPLEMENTATION_SUMMARY.md) - Technical overview
- [Apple Docs: NSUbiquitousKeyValueStore](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore)
