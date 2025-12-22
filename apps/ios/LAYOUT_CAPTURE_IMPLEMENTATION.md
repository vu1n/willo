# Save Current Layout Feature - Implementation Guide

## Overview

This feature allows users to capture their current zellij pane arrangement and save it as a reusable layout template. Users can then apply these saved layouts when creating new sessions or switching between different workspace configurations.

## Architecture

### 1. Data Models

#### UserLayout (`WilloSession.swift`)
```swift
struct UserLayout: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let kdlContent: String
    let createdAt: Date
    let deviceOrigin: DeviceOrigin
}
```

- **Purpose**: Represents a user-created layout captured from a zellij session
- **Storage**: Persisted via `LayoutStore` in UserDefaults
- **Device Origin**: Tracks which device type (phone/tablet/desktop) created the layout for better filtering

#### LayoutTemplate Enhancement (`WilloSession.swift`)
- Added `isUserCreated: Bool` property to distinguish user layouts from built-in templates
- Updated initializer to accept this parameter

### 2. Storage Layer

#### LayoutStore (`LayoutStore.swift`)
```swift
@MainActor
final class LayoutStore: ObservableObject {
    @Published private(set) var userLayouts: [UserLayout]

    func addLayout(name: String, kdlContent: String) -> UserLayout
    func deleteLayout(_ layoutId: UUID)
    func renameLayout(_ layoutId: UUID, newName: String)
    func getLayout(_ layoutId: UUID) -> UserLayout?
    func getAllLayoutTemplates() -> [LayoutTemplate]
}
```

- **Purpose**: Manages user-created layouts with CRUD operations
- **Persistence**: UserDefaults key: `"willoUserLayouts"`
- **Integration**: Added to `AppServices` singleton and injected as environment object

### 3. User Interface

#### LayoutPickerView Updates
- **User Layouts Section**: Displays saved layouts under "MY LAYOUTS" header
- **Delete Functionality**: Trash button overlay on user-created layout cards
- **Visual Distinction**:
  - User layouts show star icon (amber color)
  - Built-in layouts show grid icon (cyan color)
  - Custom schematic for unknown/user layouts

#### SaveLayoutSheet (`SaveLayoutSheet.swift`)
- **Purpose**: Modal sheet for naming and saving captured layouts
- **Features**:
  - Text input for layout name
  - Loading state during capture
  - Error display
  - Consistent Willo design system (industrial aesthetic)
- **Callback**: `onCaptureLayout` receives a completion handler with Result<String, Error>

#### CommandPaletteView Updates
- **New Category**: Added `.layout` category for layout management commands
- **Save Command**: "Save Current Layout" command with special handling
- **Integration**: `onSaveLayout` callback triggers the save layout sheet

### 4. Layout Capture Flow

#### Current Implementation (Template-Based)
```swift
private func captureLayout(session: TerminalSession,
                          completion: @escaping (Result<String, Error>) -> Void) {
    // Returns a template layout for demonstration
    // Future: Implement actual capture via SFTP or terminal output parsing
}
```

**User Flow**:
1. User opens Command Palette (⌘K)
2. Selects "Save Current Layout"
3. SaveLayoutSheet appears
4. User enters a name for the layout
5. System captures layout (currently returns template)
6. Layout saved to LayoutStore
7. Immediately available in Layout Picker

#### Future Implementation Options

**Option A: SFTP File Read**
```swift
// 1. Send dump command to server
let command = "zellij action dump-layout > /tmp/willo-layout.kdl\n"
await session.transport.send(Data(command.utf8))

// 2. Use SFTP to read the file
let sftpClient = session.createSFTPClient()
let content = try await sftpClient.readFile("/tmp/willo-layout.kdl")

// 3. Clean up
await session.transport.send(Data("rm /tmp/willo-layout.kdl\n".utf8))
```

**Option B: Terminal Output Capture**
```swift
// Requires extending TerminalSession transport layer
let outputCapture = session.transport.startCapture()
let command = "zellij action dump-layout\n"
await session.transport.send(Data(command.utf8))
let content = try await outputCapture.waitForOutput(timeout: 3.0)
```

**Option C: OSC 52 Clipboard Integration**
```swift
// Use OSC 52 escape sequences to copy to system clipboard
let command = "zellij action dump-layout | /path/to/osc52-copy\n"
await session.transport.send(Data(command.utf8))
let content = try await UIPasteboard.general.waitForContent()
```

### 5. Layout Application

#### executeStartupCommand() Updates
```swift
// Check both built-in and user layouts
var layoutToUse: LayoutTemplate?
if let layoutId = layoutId {
    // Check built-in first
    if let builtIn = LayoutTemplate.builtIn.first(where: { $0.id == layoutId }) {
        layoutToUse = builtIn
    }
    // Then check user layouts
    else if let uuid = UUID(uuidString: layoutId),
            let userLayout = layoutStore.getLayout(uuid) {
        layoutToUse = userLayout.toLayoutTemplate()
    }
}
```

- User layouts are checked after built-in layouts
- Converted to LayoutTemplate for consistent handling
- Written to `/tmp/willo-layout-{id}-v{hash}.kdl` on server
- Used with `zellij --new-session-with-layout` command

## Files Modified/Created

### Created Files
1. `/Users/vuln/code/willo/apps/ios/Willo/Sources/Store/LayoutStore.swift`
   - Layout persistence and management

2. `/Users/vuln/code/willo/apps/ios/Willo/Sources/Views/Components/SaveLayoutSheet.swift`
   - UI for naming and saving layouts

### Modified Files
1. `/Users/vuln/code/willo/apps/ios/Willo/Sources/Models/WilloSession.swift`
   - Added `UserLayout` model
   - Updated `LayoutTemplate` with `isUserCreated` property

2. `/Users/vuln/code/willo/apps/ios/Willo/Sources/Views/Components/LayoutPickerView.swift`
   - Added user layouts section
   - Delete functionality for user layouts
   - Updated schematic rendering
   - Environment object integration

3. `/Users/vuln/code/willo/apps/ios/Willo/Sources/Views/CommandPaletteView.swift`
   - Added `.layout` category
   - "Save Current Layout" command
   - `onSaveLayout` callback support

4. `/Users/vuln/code/willo/apps/ios/Willo/Sources/Views/TerminalWorkspaceView.swift`
   - Save layout sheet integration
   - Layout capture function
   - Updated layout loading logic

5. `/Users/vuln/code/willo/apps/ios/Willo/Sources/App/WilloApp.swift`
   - Added `layoutStore` to `AppServices`
   - Environment object injection

## Usage Instructions

### For Users

1. **Save a Layout**:
   - Open Command Palette with ⌘K or status bar button
   - Search for "Save Current Layout"
   - Enter a name for your layout
   - Tap "Save Layout"

2. **Use a Saved Layout**:
   - Create/edit a session
   - Open Layout Picker
   - Select your saved layout from "MY LAYOUTS" section
   - Layout will be applied when connecting to the session

3. **Delete a Layout**:
   - Open Layout Picker
   - Tap the trash icon on the layout card
   - Layout is immediately removed

### For Developers

#### Implementing Real Layout Capture

To implement actual layout capture (beyond the template):

1. **Add SFTP Support** (Recommended):
```swift
// In TerminalSession or SessionManager
func readRemoteFile(_ path: String) async throws -> String {
    // Implement SFTP read
}
```

2. **Update captureLayout()**:
```swift
private func captureLayout(session: TerminalSession,
                          completion: @escaping (Result<String, Error>) -> Void) {
    Task {
        do {
            let timestamp = Date().timeIntervalSince1970
            let layoutPath = "/tmp/willo-layout-\(timestamp).kdl"

            // Dump to file
            let cmd = "zellij action dump-layout > \(layoutPath)\n"
            try await session.transport.send(Data(cmd.utf8))

            // Wait for file
            try await Task.sleep(nanoseconds: 500_000_000)

            // Read via SFTP
            let content = try await session.readRemoteFile(layoutPath)

            // Clean up
            try await session.transport.send(Data("rm \(layoutPath)\n".utf8))

            await MainActor.run {
                completion(.success(content))
            }
        } catch {
            await MainActor.run {
                completion(.failure(error))
            }
        }
    }
}
```

#### Testing

1. **Manual Testing**:
   - Run the app
   - Connect to a zellij session
   - Create some panes (split vertical/horizontal)
   - Open Command Palette and save layout
   - Verify layout appears in picker
   - Create new session with saved layout

2. **Preview Testing**:
   - SaveLayoutSheet preview shows capture flow
   - LayoutPickerView preview shows layout grid

## Design Decisions

### Why Template for Capture?
Currently returns a template layout because:
- Terminal output capture requires transport layer changes
- SFTP not yet implemented in session manager
- Provides working UI/UX for user testing
- Easy to swap with real implementation

### Why UserDefaults for Storage?
- Simple persistence for user preferences
- Fast read/write for small data
- Could migrate to file system or CloudKit later
- Consistent with other app settings

### Why Separate from Built-in Layouts?
- Different lifecycle (user can delete)
- Different display requirements (show creation date)
- Different icon/color scheme
- Clear visual distinction for user

### Why LayoutStore vs SessionStore?
- Separation of concerns
- Layouts are reusable across sessions
- Independent lifecycle
- Could support layout sharing/export later

## Future Enhancements

1. **Layout Export/Import**:
   - Export as .kdl file
   - Share layouts between devices
   - Import community layouts

2. **Layout Preview**:
   - Better schematic generation from KDL
   - Show pane names/sizes
   - Interactive preview

3. **Smart Capture**:
   - Detect pane types (editor, terminal, logs)
   - Auto-name layouts based on content
   - Suggest similar existing layouts

4. **Cloud Sync**:
   - iCloud sync via CloudSyncManager
   - Merge strategy for conflicts
   - Device-specific vs universal layouts

5. **Layout Templates**:
   - Convert user layouts to templates
   - Parameterize layouts (pane sizes, counts)
   - Layout categories/tags

## Known Limitations

1. **No Real Capture**: Currently returns template layout
2. **No Preview**: Can't see layout structure before applying
3. **No Rename**: Must delete and recreate to rename
4. **No Validation**: KDL content not validated before save
5. **No Deduplication**: Can save duplicate layouts

## Migration Notes

If implementing real capture via SFTP:
- No data migration needed
- UserLayout model compatible
- Update only `captureLayout()` function
- Consider adding validation step

## Performance Considerations

- UserDefaults read on app launch (LayoutStore init)
- O(n) lookup for user layouts by ID
- Consider caching LayoutTemplate conversions if n > 100
- Layout file writes use versioned filenames for cache invalidation
