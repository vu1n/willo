//! Willo Bridge Plugin for Zellij
//!
//! This plugin provides a bidirectional JSON communication channel between
//! Zellij and the Willo iPad app via the `zellij pipe` command.
//!
//! Protocol: NDJSON (newline-delimited JSON)
//! - Each message is a single JSON object followed by a newline
//! - Messages from plugin -> client contain full state (not deltas)
//! - Messages from client -> plugin are commands

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::time::{Duration, Instant};
use zellij_tile::prelude::*;

// Register the plugin with Zellij
register_plugin!(WilloBridge);

/// Main plugin state
#[derive(Default)]
struct WilloBridge {
    /// Connected pipe clients (pipe_id -> client state)
    pipe_clients: HashMap<String, PipeClient>,
    /// Current session name (populated from SessionUpdate)
    session_name: String,
    /// Cached tab state for snapshot replay
    cached_tabs: Option<Vec<TabInfo>>,
    /// Cached pane state for snapshot replay
    cached_panes: Option<PaneManifest>,
}

/// Per-client state
struct PipeClient {
    /// Unique pipe ID
    #[allow(dead_code)]
    pipe_id: String,
    /// Whether we've sent the hello frame
    sent_hello: bool,
    /// Whether we've sent the initial snapshot
    sent_snapshot: bool,
    /// Per-client input buffer for NDJSON parsing
    input_buffer: String,
    /// Last time we received data from this client (for heartbeat timeout)
    last_seen: Instant,
}

impl Default for PipeClient {
    fn default() -> Self {
        Self {
            pipe_id: String::new(),
            sent_hello: false,
            sent_snapshot: false,
            input_buffer: String::new(),
            last_seen: Instant::now(),
        }
    }
}

/// Command received from client
#[derive(Deserialize, Debug)]
struct BridgeCommand {
    #[allow(dead_code)]
    v: i32,
    #[serde(rename = "type")]
    type_field: String,
    direction: Option<String>,
    #[serde(rename = "paneId")]
    pane_id: Option<u32>,
    #[serde(rename = "tabId")]
    tab_id: Option<u32>,
    name: Option<String>,
    layout: Option<String>,
}

/// Protocol envelope for outgoing messages
#[derive(Serialize)]
struct BridgeEnvelope<T: Serialize> {
    v: i32,
    session: String,
    ts: u128,
    #[serde(rename = "type")]
    msg_type: String,
    payload: T,
}

/// Hello payload
#[derive(Serialize)]
struct HelloPayload {
    #[serde(rename = "pluginVersion")]
    plugin_version: String,
    #[serde(rename = "zellijVersion")]
    zellij_version: String,
    #[serde(rename = "protocolVersion")]
    protocol_version: i32,
}

/// Tab update payload
#[derive(Serialize)]
struct TabUpdatePayload<'a> {
    tabs: &'a Vec<TabInfo>,
}

/// Pane update payload
#[derive(Serialize)]
struct PaneUpdatePayload<'a> {
    panes: &'a PaneManifest,
}

/// Session update payload
#[derive(Serialize)]
struct SessionUpdatePayload<'a> {
    sessions: &'a Vec<SessionInfo>,
}

// Heartbeat timeout - prune clients that haven't sent data in 30 seconds
const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(30);

impl ZellijPlugin for WilloBridge {
    fn load(&mut self, _config: BTreeMap<String, String>) {
        // Request permissions we need
        request_permission(&[
            PermissionType::ReadApplicationState,
            PermissionType::ChangeApplicationState,
        ]);

        // Subscribe to events we care about
        subscribe(&[
            EventType::TabUpdate,
            EventType::PaneUpdate,
            EventType::SessionUpdate,
            EventType::ModeUpdate,
        ]);
    }

    fn pipe(&mut self, pipe_message: PipeMessage) -> bool {
        if let PipeSource::Cli(ref pipe_id) = pipe_message.source {
            let pipe_id = pipe_id.clone();

            // Add new client if not tracked
            if !self.pipe_clients.contains_key(&pipe_id) {
                let client = PipeClient {
                    pipe_id: pipe_id.clone(),
                    sent_hello: false,
                    sent_snapshot: false,
                    input_buffer: String::new(),
                    last_seen: Instant::now(),
                };
                self.pipe_clients.insert(pipe_id.clone(), client);
            }

            // Collect what we need to do to avoid borrow issues
            let (needs_hello, needs_snapshot) = {
                let client = self.pipe_clients.get_mut(&pipe_id).unwrap();
                client.last_seen = Instant::now();

                // Buffer incoming data
                if let Some(payload) = pipe_message.payload {
                    client.input_buffer.push_str(&payload);
                }

                let needs_hello = !client.sent_hello;
                let needs_snapshot = !client.sent_snapshot;

                if needs_hello {
                    client.sent_hello = true;
                }
                if needs_snapshot {
                    client.sent_snapshot = true;
                }

                (needs_hello, needs_snapshot)
            };

            // Now send hello/snapshot without holding mutable borrow
            if needs_hello {
                self.send_hello_to(&pipe_id);
            }
            if needs_snapshot {
                self.send_snapshot_to(&pipe_id);
            }

            // Process commands
            self.process_client_commands(&pipe_id);
        }

        true // Keep plugin running
    }

    fn update(&mut self, event: Event) -> bool {
        match event {
            Event::TabUpdate(tabs) => {
                // Cache for snapshot replay
                self.cached_tabs = Some(tabs.clone());
                self.broadcast_tab_update(&tabs);
            }
            Event::PaneUpdate(panes) => {
                // Cache for snapshot replay
                self.cached_panes = Some(panes.clone());
                self.broadcast_pane_update(&panes);
            }
            Event::SessionUpdate(sessions, _) => {
                // Extract current session name
                if let Some(current) = sessions.iter().find(|s| s.is_current_session) {
                    self.session_name = current.name.clone();
                }
                self.broadcast_session_update(&sessions);
            }
            Event::ModeUpdate(_mode) => {
                // Could broadcast mode changes if needed
            }
            _ => {}
        }

        true // Keep plugin running
    }
}

impl WilloBridge {
    /// Create a protocol envelope
    fn make_envelope<T: Serialize>(&self, msg_type: &str, payload: T) -> String {
        let envelope = BridgeEnvelope {
            v: 1,
            session: if self.session_name.is_empty() {
                "unknown".to_string()
            } else {
                self.session_name.clone()
            },
            ts: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis())
                .unwrap_or(0),
            msg_type: msg_type.to_string(),
            payload,
        };
        serde_json::to_string(&envelope).unwrap_or_default()
    }

    /// Send hello frame to a specific client
    fn send_hello_to(&self, pipe_id: &str) {
        let payload = HelloPayload {
            plugin_version: env!("CARGO_PKG_VERSION").to_string(),
            zellij_version: get_zellij_version(),
            protocol_version: 1,
        };
        let msg = self.make_envelope("hello", payload);
        cli_pipe_output(pipe_id, &format!("{}\n", msg));
    }

    /// Send cached snapshot to a specific client
    fn send_snapshot_to(&self, pipe_id: &str) {
        // Send cached tabs
        if let Some(ref tabs) = self.cached_tabs {
            let payload = TabUpdatePayload { tabs };
            let msg = self.make_envelope("tabUpdate", payload);
            cli_pipe_output(pipe_id, &format!("{}\n", msg));
        }

        // Send cached panes
        if let Some(ref panes) = self.cached_panes {
            let payload = PaneUpdatePayload { panes };
            let msg = self.make_envelope("paneUpdate", payload);
            cli_pipe_output(pipe_id, &format!("{}\n", msg));
        }
    }

    /// Broadcast tab update to all clients
    fn broadcast_tab_update(&mut self, tabs: &Vec<TabInfo>) {
        let payload = TabUpdatePayload { tabs };
        let msg = format!("{}\n", self.make_envelope("tabUpdate", payload));
        self.broadcast(&msg);
    }

    /// Broadcast pane update to all clients
    fn broadcast_pane_update(&mut self, panes: &PaneManifest) {
        let payload = PaneUpdatePayload { panes };
        let msg = format!("{}\n", self.make_envelope("paneUpdate", payload));
        self.broadcast(&msg);
    }

    /// Broadcast session update to all clients
    fn broadcast_session_update(&mut self, sessions: &Vec<SessionInfo>) {
        let payload = SessionUpdatePayload { sessions };
        let msg = format!("{}\n", self.make_envelope("sessionUpdate", payload));
        self.broadcast(&msg);
    }

    /// Broadcast a message to all connected clients, pruning stale ones
    fn broadcast(&mut self, message: &str) {
        let now = Instant::now();
        let mut stale_ids: Vec<String> = Vec::new();

        for (pipe_id, client) in &self.pipe_clients {
            // Check heartbeat timeout - only way to detect dead clients
            // since cli_pipe_output returns () not a success indicator
            if now.duration_since(client.last_seen) > HEARTBEAT_TIMEOUT {
                stale_ids.push(pipe_id.clone());
                continue;
            }

            // Send to client
            cli_pipe_output(pipe_id, message);
        }

        // Remove stale clients
        for id in stale_ids {
            self.pipe_clients.remove(&id);
        }
    }

    /// Process NDJSON-buffered commands for a specific client
    fn process_client_commands(&mut self, client_id: &str) {
        // Extract complete lines from the client's buffer
        let lines_to_process: Vec<String> = {
            let client = match self.pipe_clients.get_mut(client_id) {
                Some(c) => c,
                None => return,
            };

            let mut lines = Vec::new();
            while let Some(newline_pos) = client.input_buffer.find('\n') {
                let line = client.input_buffer[..newline_pos].to_string();
                client.input_buffer = client.input_buffer[newline_pos + 1..].to_string();
                if !line.trim().is_empty() {
                    lines.push(line);
                }
            }
            lines
        };

        // Process extracted lines
        for line in lines_to_process {
            self.handle_command(&line, client_id);
        }
    }

    /// Handle a single command from a client
    fn handle_command(&mut self, line: &str, from_client_id: &str) {
        let cmd: BridgeCommand = match serde_json::from_str(line) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("[WilloBridge] Invalid command: {} - {}", line, e);
                return;
            }
        };

        match cmd.type_field.as_str() {
            "newPane" => {
                // Open a new tiled terminal pane in current working directory
                // The path "." means current directory
                open_terminal(".");

                // If direction specified, try to move focus that way
                // This doesn't guarantee placement but hints at intent
                if let Some(dir_str) = cmd.direction {
                    let direction = match dir_str.as_str() {
                        "up" => Some(Direction::Up),
                        "down" => Some(Direction::Down),
                        "left" => Some(Direction::Left),
                        "right" => Some(Direction::Right),
                        _ => None,
                    };
                    if let Some(dir) = direction {
                        move_focus(dir);
                    }
                }
            }
            "newTab" => {
                // Open a new tab
                if let Some(ref layout) = cmd.layout {
                    // Use layout if specified
                    new_tabs_with_layout(layout);
                } else {
                    // Create a new tab with default layout
                    new_tab();
                }
            }
            "focus" => {
                // Focus a specific pane
                if let Some(pane_id) = cmd.pane_id {
                    focus_terminal_pane(pane_id, true);
                }
            }
            "focusTab" => {
                // Focus a specific tab
                if let Some(tab_id) = cmd.tab_id {
                    go_to_tab(tab_id);
                }
            }
            "applyLayout" => {
                // Apply a layout
                if let Some(ref name) = cmd.name {
                    new_tabs_with_layout(name);
                }
            }
            "requestSnapshot" => {
                // Send current state to requesting client
                self.send_snapshot_to(from_client_id);
            }
            "ping" => {
                // Heartbeat - just update last_seen (already done in pipe())
            }
            _ => {
                eprintln!("[WilloBridge] Unknown command type: {}", cmd.type_field);
            }
        }
    }
}
