# iCloud Sync Setup

This document describes how to enable iCloud Key-Value Storage for the Willo iOS app to sync sessions and server profiles across devices.

## What Gets Synced

The CloudSyncManager syncs the following data using NSUbiquitousKeyValueStore:

1. **WilloSession metadata**:
   - Session name, description, color
   - Layout ID
   - Created/last activity timestamps
   - Device origin
   - Server profile reference (by ID)
   - **NOT synced**: Terminal state, connection status, active terminal sessions

2. **ServerProfile definitions**:
   - Display name, hostname, port, username
   - Multiplexer preference, startup behavior
   - Session template
   - **NOT synced**: Passwords (these stay in device-local storage/Keychain)

3. **Future: Custom Layout Templates** (when implemented):
   - User-created KDL layout definitions

## Storage Limits

NSUbiquitousKeyValueStore has the following limits:
- **Total storage**: 1 MB per app
- **Maximum keys**: 1,024 keys
- **Maximum value size**: 1 MB per key

For Willo's use case (session and profile metadata), this is more than sufficient. A typical setup with 50 sessions and 20 server profiles uses less than 100 KB.

## Xcode Project Setup

To enable iCloud sync, you need to configure the Xcode project:

### 1. Enable iCloud Capability

1. Open the Willo project in Xcode
2. Select the **Willo** target
3. Go to the **Signing & Capabilities** tab
4. Click **+ Capability**
5. Select **iCloud**
6. Check **Key-value storage**
7. Uncheck other iCloud services (CloudKit, iCloud Documents) if not needed

### 2. Configure Entitlements

The entitlements file (`Willo.entitlements`) should include:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.ubiquity-kvstore-identifier</key>
    <string>$(TeamIdentifierPrefix)$(CFBundleIdentifier)</string>
</dict>
</plist>
```

Xcode usually creates this automatically when you enable the iCloud capability.

### 3. Verify App ID and Provisioning Profile

1. Go to [Apple Developer Portal](https://developer.apple.com/)
2. Navigate to **Certificates, Identifiers & Profiles**
3. Select your app's **App ID**
4. Ensure **iCloud** is enabled in the capabilities list
5. Regenerate provisioning profiles if needed

### 4. Test iCloud Availability

The CloudSyncManager checks if iCloud is available at runtime:

```swift
// Check in CloudSyncManager.swift
isAvailable = FileManager.default.ubiquityIdentityToken != nil
```

If iCloud is not available:
- User is not signed into iCloud on their device
- iCloud Drive is disabled in Settings
- The app doesn't have the correct entitlements

## How Sync Works

### Automatic Sync

- **On app launch**: CloudSyncManager loads data from iCloud and merges with local data
- **On data change**: When sessions or profiles are modified, they're automatically synced to iCloud
- **External changes**: When data changes on another device, the app receives a notification and merges the changes

### Merge Strategy

The implementation uses a **last-write-wins** strategy based on timestamps:

**For Sessions**:
- Compare `lastActivityAt` timestamps
- Newer activity wins
- Session must have matching server profile (by ID)

**For Server Profiles**:
- Compare `lastConnected` timestamps
- Newer connection wins
- **Passwords are preserved locally** - never synced to cloud

### Conflict Resolution

If both devices modify the same session/profile:
1. The device with the most recent timestamp wins
2. Changes are merged on next sync
3. No user intervention required

For more complex conflict scenarios (e.g., simultaneous edits), the last sync wins. This is appropriate for metadata like session names and colors.

## Security Considerations

### What's Safe to Sync

✅ **Safe**:
- Session names, descriptions, colors
- Layout preferences
- Server hostnames, usernames, ports
- Connection preferences

❌ **NOT synced** (kept device-local):
- Passwords (stored in UserDefaults or Keychain)
- SSH keys (stored in Keychain)
- Active terminal state
- Command history

### Privacy

- Data synced via NSUbiquitousKeyValueStore is:
  - Encrypted in transit
  - Encrypted at rest on Apple's servers
  - Only accessible to devices signed into the same iCloud account
  - Subject to Apple's iCloud terms and privacy policy

## Testing

### Test on Multiple Devices

1. **Device A**: Create a session or server profile
2. Wait a few seconds for sync
3. **Device B**: Open the app - should see the new session/profile
4. **Device B**: Modify the session
5. **Device A**: Should see the updated session after a few seconds

### Test Without iCloud

1. Sign out of iCloud on the device
2. The app continues to work normally using local storage
3. When iCloud is re-enabled, data syncs automatically

### Monitoring Sync

Check Xcode console for sync messages:

```
[CloudSync] iCloud available - setting up sync
[CloudSync] Synced 5 sessions to iCloud
[CloudSync] External change detected - reason: 0, keys: ["willo.sessions.v1"]
[SessionStore] Merging 5 sessions from iCloud
```

## Troubleshooting

### Sync Not Working

**Check iCloud is enabled**:
- Settings → [Your Name] → iCloud
- Ensure iCloud Drive is ON
- Check app has iCloud permission

**Verify entitlements**:
```bash
codesign -d --entitlements :- /path/to/Willo.app
```

Should show `com.apple.developer.ubiquity-kvstore-identifier` key.

**Force sync**:
```swift
// In CloudSyncManager
cloudSync.forceSynchronize()
```

### Data Not Appearing on Other Device

1. Check both devices are signed into the same iCloud account
2. Ensure both devices have internet connectivity
3. Wait a few minutes - initial sync can take time
4. Check console logs for errors

### Quota Exceeded

If you hit the 1MB limit (unlikely):
- CloudSyncManager will log: `iCloud storage quota exceeded`
- Reduce data by removing old sessions
- Consider pruning session history

## Implementation Details

### File Structure

```
Willo/Sources/Store/
├── CloudSyncManager.swift    # iCloud sync implementation
├── SessionStore.swift         # Uses CloudSyncManager for sessions
└── ThumbnailManager.swift

Willo/Sources/App/
└── WilloApp.swift             # AppState uses CloudSyncManager for profiles
```

### Key Types

**CloudSyncManager**: Main sync coordinator
- Uses NSUbiquitousKeyValueStore
- Publishes sync events via Combine
- Handles merge conflicts

**SyncableSession**: Codable version of WilloSession for cloud storage
- Excludes runtime state (connection, activity)
- References server profile by ID only

**SyncableServerProfile**: Codable version of ServerProfile for cloud storage
- Excludes passwords (sanitized during sync)
- Preserves all other settings

### Sync Flow

```
Local Change → SessionStore/AppState → CloudSyncManager → NSUbiquitousKeyValueStore
                                                                    ↓
                                                              iCloud Servers
                                                                    ↓
External Change Notification → CloudSyncManager → Merge → Update Local Store
```

## Future Enhancements

Potential improvements:

1. **Custom Layout Sync**: Sync user-created KDL layouts
2. **Selective Sync**: Allow users to choose what to sync
3. **Conflict UI**: Show users when conflicts occur and let them choose
4. **Sync Status Indicator**: Visual feedback in UI showing sync state
5. **Manual Sync Button**: Force sync on demand
6. **CloudKit Migration**: For more advanced features (file storage, structured data)

## References

- [Apple Docs: NSUbiquitousKeyValueStore](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore)
- [Apple Docs: iCloud Design Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/)
- [Apple Docs: Key-Value Storage](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore)
