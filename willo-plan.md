# iPad Terminal App (iPad Pro) – Agent Kickoff Doc

## 0) One‑sentence goal

Build a **fast, resilient iPad terminal** for development work that excels at **keyboard-driven UX**, prioritizes **spotty-connection resilience (mosh-style roaming)**, and uses **server-side multiplexing (zellij/tmux)** while the iPad app provides a **tabbed, workspace-first interface**.

---

## 1) Product goals

### Must-have

* **Tabbed interface** for multiple concurrent work contexts (servers / sessions).
* **Great hardware keyboard UX** (Esc/Ctrl/Alt/Meta mapping, ⌘ shortcuts, IME safety).
* **Low-latency feel** with smooth scrolling and rapid redraw.
* **Roaming/spotty-connection resilience** as a first-class pillar:

  * **mosh** when available
  * clean **fallback to SSH + fast reattach** when UDP/mosh is unavailable
* **Disconnect/reconnect safe**: sessions continue on server via **tmux/zellij**.

### Nice-to-have

* Split view / multiwindow support (Stage Manager).
* Session templates (“Agent swarm workspace” layout button).
* Clipboard sync, hyperlink support, search in scrollback.
* Optional Tailscale-friendly workflows (assume user runs Tailscale app).

### Non-goals (v0)

* Building a full multiplexer on-device.
* Embedding a full VPN client (Tailscale in-app) from day 1.
* Android UI parity (design for it, but ship iPad first).

---

## 2) Key UX decisions

### 2.1 Client tabs vs server panes

* **Client tabs** = distinct “Workspaces” (server profile + session).
* **Server panes/tabs** = actual concurrency (zellij/tmux) so work persists when iPad sleeps.

### 2.2 “Fast feedback” workflow

* Prefer **mosh** when supported, fall back to **SSH**.
* Always start/attach to a server-side multiplexer session:

  * zellij: `zellij attach -c <session>`
  * tmux: `tmux new -A -s <session>`

### 2.3 First-run experience

* Create a “Devbox” profile (host/user/auth).
* Connect → auto-attach/create multiplexer session.
* Show a minimal command palette (⌘K) with actions:

  * New tab/workspace
  * Reconnect
  * Copy/paste
  * (Later) zellij actions (new pane/tab, focus move)

---

## 3) Tech strategy

### 3.1 Native iPad app

* Language/UI: **Swift**
* Shell: **SwiftUI** (tabs, settings, profiles)
* Terminal view: **UIKit + MetalKit** (for deterministic input/render loop)

### 3.2 Terminal emulation core

* Use **libghostty-vt** for VT parsing + terminal state.
* Do **NOT** bind UI directly to libghostty’s evolving API.
* Create our own stable wrapper:

  * `TerminalCore` (C ABI) → Swift bridges.
  * Goal: keep FFI **chunky** (bulk feed, bulk diff) not per-cell.

**Key technical risk: Ghostty is written in Zig.**

* We cannot treat libghostty-vt like a plain C library.
* We need an explicit **Zig → iOS cross-compilation pipeline** to produce a static library or XCFramework for `arm64-apple-ios`.
* The Zig side must explicitly export a C ABI (e.g., `export fn tc_create(...) ...`).
* Make “toolchain POC” a Week 1 / Phase 0 gate to fail fast if build plumbing is painful.

### 3.3 Renderer model

* Renderer consumes **Frame Diffs** from TerminalCore:

  * Dirty row ranges / dirty rectangles
  * Runs of styled glyphs (attributes + text)
  * Cursor state
* Renderer maintains:

  * Glyph atlas cache
  * Font fallback and shaping
  * Selection overlays

**Text shaping trap (do not underestimate):**

* Drawing a grid in Metal is easy; **Unicode text shaping** (emoji sequences, combining marks, ligatures, Nerd Fonts) is hard.
* For v0, do **NOT** build a custom shaper.

Recommended v0 approach:

* Use **CoreText** to shape text into glyph runs.
* Cache shaped glyph bitmaps into a Metal texture atlas.

Optional later approach (if needed for portability or performance):

* Integrate **HarfBuzz** for shaping and feed glyph indices/positions into Metal.

### 3.4 Networking

* v0: SSH transport (reliable baseline)
* v0+: “roaming feel” comes primarily from **server-side persistence** (zellij/tmux) + fast reconnect.
* v1: evaluate mosh-like roaming transport (see licensing decision matrix).

### 3.5 Tailscale

* v0: **assume user runs official Tailscale app** → we just connect to tailnet addresses.
* Do not embed PacketTunnel / NetworkExtension until later.

### 3.6 Zellij Bridge (structure-aware UI)

**What it is:** a side-channel “control + telemetry plane” between the iPad app and a zellij session.

Instead of only sending keystrokes, the app can:

* **Observe** zellij structure (sessions / tabs / panes / titles / focused pane)
* **Control** zellij structure (open/close panes, create tabs, apply layouts, rename, focus)
* Keep the iPad UI (tabs/sidebar) in sync with what’s actually happening server-side.

**Why it matters:** this is how we become an “iPad IDE for remote work” rather than “just another terminal.”

#### Bridge scope (formalize as an interface)

* Bridge is **best-effort**: if it fails, terminal still works.
* Bridge is **session-scoped** (per remote zellij session).
* Bridge must not add meaningful latency to terminal I/O.

#### Bridge v1 (pragmatic, minimal, shippable)

* **Control:** issue zellij CLI actions over SSH:

  * `zellij --session <name> action ...` (new-pane, new-tab, focus, rename, etc.)
* **Session discovery:** `zellij list-sessions` over SSH.
* **Layouts:** start/attach with layouts (KDL) and templates.

This gets us 80% of value: native buttons for “New Agent Pane”, “Apply Swarm Layout”, etc.

#### Bridge v2 (structure mirroring, the real magic)

Use **Zellij Pipes + a small bridge plugin** so we can stream structured state updates.

Mechanism:

* On connect, open a second SSH channel that runs a long-lived pipe:

  * `zellij pipe --name wisp_bridge --plugin file:~/.wispterm/wisp_bridge.wasm --`
  * This can take input on STDIN and return plugin output on STDOUT. (CLI pipe supports this.)
* The bridge plugin subscribes to zellij application state events:

  * `TabUpdate`, `PaneUpdate` (requires `ReadApplicationState` permission)
* The plugin emits **JSON Lines** to the pipe STDOUT:

  * `{"type":"pane_update", ...}`
  * `{"type":"tab_update", ...}`
* Optionally, the iPad app can send JSON commands into the pipe STDIN:

  * `{"type":"command","op":"apply_layout","layout":"swarm"}`
  * Plugin can respond via `cli_pipe_output` (requires `ReadCliPipes` permission).

References:

* CLI pipe semantics and STDIN↔STDOUT behavior.
* Plugin API events include TabUpdate/PaneUpdate.

#### Bridge protocol (formalize now so we don’t paint ourselves into a corner)

Define a versioned protocol:

* All messages are JSON lines.
* Every message includes:

  * `v` (protocol version)
  * `session` (zellij session name)
  * `ts` (unix ms)
  * optional `req_id` for request/response pairing

Event types (from server → iPad):

* `session_list`
* `tab_update` (tab id/index, name, active, fullscreen, hidden panes)
* `pane_update` (pane id, title, command, is_floating, exit_code?)
* `focus_update` (active tab + focused pane)

Command types (from iPad → server):

* `new_tab { name?, layout? }`
* `new_pane { direction?, cmd? }`
* `focus { tab_id?, pane_id? }`
* `rename_tab / rename_pane`
* `apply_layout { layout_name | layout_path }`

#### Deep-linkable “Agent Start” (formalize)

* Support URL scheme like: `wispterm://bookmark/<id>?layout=swarm`
* Behavior: launch → connect → attach/create session → apply layout → focus first pane.

---

## 4) Licensing / risk notes

#### 4.1 mosh licensing (decision matrix)

* Upstream mosh is GPL.

Implications if we embed/link mosh code in a distributed app build:

* Expect GPL obligations (source availability for recipients; downstream redistribution rights).
* App Store distribution can be legally/operationally tricky; treat as “needs careful review.”

Strategic options:

* **v0 release: SSH-first** + zellij/tmux persistence + fast reattach (covers most practical needs).
* **Development-only mosh**: use mosh locally for our own builds to validate UX/latency.
* **Commercial paths**:

  * Path A: ship as GPL (open source the app; monetize via distribution/services/support).
  * Path B: remain proprietary and replace mosh with:

    * clean-room roaming client (large scope), or
    * alternative permissive roaming transport (evaluate), or
    * “SSH reconnection layer” + zellij/tmux reattach (often sufficient).

### 4.2 iPadOS lifecycle

* Expect suspension in background.
* Design for:

  * quick reconnect
  * server-side persistence via tmux/zellij
  * explicit “Connection keepalive” mode (if feasible later)

---

## 5) Architecture overview

### 5.1 Modules

* **AppShell (SwiftUI)**

  * Workspace tabs, server profiles, settings
  * Command palette
* **TerminalView (UIKit/Metal)**

  * Input → core
  * Core diffs → render
  * Selection, copy/paste
* **TerminalCore (C ABI wrapper)**

  * Uses libghostty-vt internally
  * Exposes stable API + diff structures
* **Transport (Swift)**

  * SSH session
  * (Later) mosh session
* **SessionController**

  * ties Transport ↔ TerminalCore ↔ TerminalView
  * reconnect logic

### 5.2 Data flow

1. Transport receives bytes → `TerminalCore.feed(bytes)`
2. Core updates state and marks dirty regions
3. Render loop requests `TerminalCore.consumeDiff()` once per frame
4. Metal renderer draws dirty regions
5. Input events → translated to terminal bytes → Transport send

---

## 6) TerminalCore – proposed API (C ABI)

### 6.1 Lifecycle

* `tc_create(config) -> tc_handle`
* `tc_destroy(handle)`

### 6.2 Input/output

* `tc_feed(handle, const uint8_t* bytes, size_t len)`
* `tc_resize(handle, uint16_t cols, uint16_t rows)`
* `tc_set_theme(handle, theme)`

### 6.3 Diff retrieval (chunky boundary)

* `tc_consume_diff(handle, tc_diff* out)`

  * dirty rows/ranges
  * cursor state
  * title changes
  * bell
  * clipboard requests

### 6.4 Cell run extraction

Two options (pick one early):

* **Option 1 (runs):** `tc_get_runs_for_row(handle, row, tc_run_buffer* out)`
* **Option 2 (snapshots):** `tc_snapshot_row(handle, row, tc_cell* out_cells)`

Prefer **runs** for fewer calls + better performance.

---

## 7) iPad UX requirements (v0)

### 7.1 Tabs

* Top tab bar (or sidebar on landscape) with:

  * server name
  * session name
  * connection status dot

### 7.2 Keyboard shortcuts

* ⌘T: new workspace tab
* ⌘W: close tab
* ⌘K: command palette
* ⌘R: reconnect
* ⌘F: find in scrollback
* Long-press / toolbar toggles for Ctrl/Esc/Alt if user lacks hardware keyboard

### 7.3 Selection

* Tap-drag selection + handles.
* Double-tap word, triple-tap line.
* Copy, “Copy as plain”, paste with bracketed paste support.

### 7.4 Port forwarding (must-have for web3/dApp dev)

* SSH local port forwarding UI to map remote ports to iPad-local ports.
* Example: remote `localhost:8080` → iPad `localhost:8080` so Safari can access dev servers.

### 7.5 Key management (security + ergonomics)

* Store SSH private keys in Keychain.
* Consider Secure Enclave-backed key storage where feasible.
* Optional later: YubiKey support (hardware-backed auth).

---

## 8) Server-side multiplexer integration

### 8.1 Detection

On connect, run:

* `command -v zellij` → if present prefer zellij
* else `command -v tmux` → fallback

### 8.2 Attach/create

* zellij: `zellij attach -c <session>`
* tmux: `tmux new -A -s <session>`

### 8.3 Zellij “powerhouse” features to lean on

We should treat zellij as the server-side **workspace engine** and expose its power through iPad-native controls.

Core zellij strengths (design the product around these):

* **Sessions as first-class objects**: users can create, attach, detach, and resume named sessions.
* **Tabs + panes**: server-side concurrency that survives disconnect/sleep.
* **Scriptable control** via CLI actions: we can drive zellij from our app by sending commands on the remote host.
* **Layouts**: pre-defined workspace templates (KDL) for consistent agent setups.

### 8.4 Session bookmarks + “resume exactly where I was”

Add a first-class concept in the iPad app:

* **Bookmarks** are client-side records that map to a server-side session.
* A bookmark stores: server profile, preferred transport (mosh/ssh), multiplexer preference (zellij/tmux), and a **session naming template**.

Bookmark behaviors:

* **One-tap Resume**: connect + attach to the session (create if missing).
* **Status hinting** (best-effort): show whether session likely exists (e.g., via a quick `zellij list-sessions` / `tmux ls` after connect).
* **“Last Active”**: store local timestamps + last command used to attach.

### 8.5 Session naming conventions (context-rich names)

Sessions should be named so they’re meaningful across devices and months later. Propose:

* Pattern: `<project>/<env>/<role>/<short-host>`

  * Examples:

    * `senfi/dev/agents/devbox1`
    * `senfi/prod/ops/prod-eu-1`
    * `bacchus/dev/build/ci-runner`

Optional suffixes:

* `@<git-branch>` (when known)
* `#<ticket>` (when user sets it)

In-app, display as:

* Title: `project · env · role`
* Subtitle: `host · session` (full string)

### 8.6 Agent workspace templates (zellij layouts)

If zellij is present, provide canned layouts as “templates”:

* **Agent Swarm**: 1 tab per agent, each tab with panes:

  * editor/llm-agent
  * logs
  * tests
* **Ops**: logs + top/btop + deploy pane
* **Research**: repl + notes + browser-driven fetch (server side)

Implementation approach:

* Ship layout files on the server (or bootstrap them on first connect).
* Provide an iPad action: “Apply Template → Agent Swarm”, which runs a zellij command to start/attach with that layout.

---

## 9) Implementation plan (first 4 weeks)

### Week 1: Zig → Swift toolchain POC (fail-fast gate)

* Establish Zig cross-compilation to iOS (`arm64-apple-ios`).
* Output `libterminalcore.a` or an XCFramework.
* Implement `tc_create()` returning a dummy “Hello World” diff.
* Swift app calls into TerminalCore successfully.

### Week 2: The “dumb” renderer

* Implement TerminalView using Metal.
* Use fixed-width font (SF Mono) and draw:

  * background grid / colored rects from diffs
  * minimal text from a simple glyph cache (no full shaping yet)

### Week 3: Transport baseline + mosh-first resilience

Key point: mosh still needs SSH to bootstrap (`mosh-server` launch + auth).

* Implement minimal **SSH bootstrap** (auth + run remote commands).
* Integrate **Mosh transport** behind `TransportSession` (dev builds first).
* Implement `TransportSSH` as fallback when:

  * UDP blocked
  * mosh-server missing
  * user forces SSH
* Add connection state machine:

  * detect network changes
  * trigger fast reconnect
  * auto-reattach to tmux/zellij session after reconnect

### Week 4: Input loop + iPad ergonomics + “coffee shop switch”

* Hardware keyboard support (UIKeyCommand + key mapping).
* Accessory key row for missing keys (Esc/Ctrl/Tab/|/~/etc.).
* Selection + copy/paste basics.
* Reconnect polish:

  * don’t hang on dead sockets
  * retry with backoff
  * clear UI state + spinner → seamless reattach

### Post-week-4: Level-up opportunities

* CoreText shaping → glyph atlas caching (make Unicode rock-solid).
* Zellij Bridge side-channel (structure-aware UI).
* Session bookmarks + deep links.
* Port forwarding UI (if not already done).
* Decide commercialization path for GPL mosh vs replacement roaming layer.

---

## 10) Acceptance tests (what “good” means)

### Performance

* Smooth scroll under high output (e.g., `tail -f` + progress bars).
* Fast redraw at 120Hz on iPad Pro in a typical dev workload.

### Correctness (practical)

* Works well with: zellij/tmux, nvim, fzf, htop/btop, ripgrep, git pager.
* Unicode: emoji + combining marks render correctly.
* Bracketed paste works in shells and nvim.

### Reliability

* Disconnect/reconnect returns to same server session.
* Server multiplexer persists work across iPad sleep.

---

## 11) Repo layout (suggested)

* `apps/ios/` – Swift app
* `core/terminalcore/` – C ABI wrapper
* `vendor/libghostty-vt/` – vendored upstream
* `docs/` – architecture notes, decisions
* `scripts/` – build scripts (XCFramework generation)

---

## 12) Immediate tasks for the agent

1. **Confirm build feasibility:** compile libghostty-vt into an iOS static lib or XCFramework.
2. Define TerminalCore C ABI structs for:

   * color/attrs
   * cursor
   * diff format
3. Build a minimal iOS terminal view that can:

   * draw monospaced text (no styling) from snapshot
   * handle keypress → send bytes
4. Stub a fake transport that feeds sample VT output (for rapid UI iteration).
5. Add first real transport (SSH) once rendering loop is stable.

---

## 13) Open decisions (record here)

* mosh: GPL embedding vs clean-room compatible client
* exact diff format (runs vs snapshots)
* which SSH library/approach to use (native vs bundled)
* keychain storage + import UX

---

## 14) What to optimize for (north star)

A terminal that **feels instant** on iPad: low input latency, crisp text, great selection, and reconnect that “just works,” while the heavy lifting (multi-agent workflows) lives safely in **zellij/tmux on the server**.

