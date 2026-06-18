# TrapBattle Server — Architecture

Server-side reference for the `trapbattle-server` dedicated server repo.
For the full cross-repo system picture see [`trapbattle/architecture.md`](../trapbattle/architecture.md).

---

## 1. Role and deployment

The dedicated server runs the **authoritative game state** for every multiplayer
session. Clients never trust each other — all damage, respawn, and win-condition
logic is decided here.

```
Internet (wss://<host>:443)
        |
    [ Caddy ]   — TLS termination, reverse proxy
        |
  127.0.0.1:9998   — Godot WebSocket server (plain ws, loopback only)
        |
  trapbattle-server (headless Linux binary)
```

| Item | Value |
|------|-------|
| Engine | Godot 4.6.3 headless Linux export |
| Listen address | `127.0.0.1:9998` (loopback only) |
| Public port | `443` (Caddy), legacy `9999` |
| VM | Azure (Ubuntu), systemd service |
| WebRTC extension | `webrtc-native` GDExtension in `addons/webrtc/lib/` (not tracked in git — deployed by `deploy.ps1`) |

Godot's embedded mbedTLS server resets browser WebSocket connections
(`mbedtls -0x6c00`). Caddy handles TLS; the server speaks plain ws.

---

## 2. Runtime startup flow

```
main.gd (_ready)
  ├── NetworkManager.new()       — starts ws server on :9998
  └── VoiceManager.new()         — created immediately so voice RPCs from clients
                                    arriving before game start are routed correctly

NetworkManager.lobby_ready (emitted when captain requests start)
  ├── GameManager.new()          — generates maze, initialises per-player state
  ├── TrapManager.new()          — tracks placed traps
  └── for each peer:
        ServerPlayer.new()       — set_multiplayer_authority(peer_id)
                                    position = spawn point from maze
```

`Config` is the **only autoload** — same constants file as the client
(`MAZE_COLS`, `MAZE_ROWS`, `MAX_HP`, `KILLS_TO_WIN`, trap enum, …).
Both repos must keep `Config` in sync so game rules are consistent.

---

## 3. WebSocket server (NetworkManager)

### Lifecycle

```
peer_connected  → _peers.append(id)
                → _rpc_lobby_update.rpc(peers, names, color_prefs)

_rpc_join_info  ← client sends name + preferred color index
                → stored in _names / _prefs

_rpc_request_start ← captain triggers
                → _do_start(): assigns colors (honor prefs, then fill gaps)
                → _rpc_start_game.rpc(seed, assignments)
                → lobby_ready.emit(seed)

peer_disconnected → _peers.erase(id)
                  → _rpc_peer_left.rpc(id)
                  → peer_left.emit(id)   -- main.gd cleans up ServerPlayer
```

### Color assignment (two-pass)

1. Any peer whose preferred color is still free gets it.
2. Remaining peers fill slots in arrival order.

### RPC stubs

Several RPCs exist on the server only as empty stubs. They run on clients,
but Godot 4 routes every `@rpc` call by the method's **position** in the
node's alphabetically-sorted `@rpc` list — not by name. The server must
declare the **identical set + decorators** even for client-only RPCs, or
every index shifts and calls get misrouted silently.

Methods that are stubs on the server:

| Method | Direction |
|--------|-----------|
| `_rpc_lobby_update` | server → all clients |
| `_rpc_start_game` | server → all clients |
| `_rpc_peer_left` | server → all clients |
| `_rpc_late_join` | server → late-joining client |
| `_rpc_spawn_late_peer` | server → existing clients |
| `_rpc_pong` | server → requesting client |

> **Rule:** whenever a new `@rpc` is added to `NetworkManager` in either repo,
> add an equivalent stub (same decorator, same signature) in the other repo at
> the **same alphabetical position**. Check with the client repo's `network_manager.gd`.

---

## 4. Maze (GameManager._init)

```
MazeGenerator.generate_maze(27, 27, extra_passages=60)
    → grid: Array[Array[int]]   0 = floor, 1 = wall
MazeGenerator.pick_spawns(grid, MAX_PLAYERS)
    → spawns[]: player spawn cells (one per player index)
    → boxes[]:  TrapBox initial positions
```

The maze seed (`Config.maze_seed`) is chosen by the server at game start and
broadcast in `_rpc_start_game`. Every peer (server + all clients) runs the
same deterministic `MazeGenerator` with that seed, producing the **identical
grid**. The server uses the grid for collision/spawn math; clients render it.

Grid units: `Config.CELL_SIZE = 2.0` world units per cell.
Helper methods on `GameManager`:

| Method | Purpose |
|--------|---------|
| `grid_to_world(cell)` | `[col, row]` → `Vector3` world centre |
| `world_to_grid(pos)` | `Vector3` → `[col, row]` |
| `is_floor(col, row)` | bounds + cell type check |
| `get_spawn_for_index(idx)` | returns the spawn cell for a player slot |
| `get_random_far_floor_cell(from, min_dist)` | used by teleport trap |

---

## 5. Game state (GameManager)

### Per-player dictionaries

| Dictionary | Type | Meaning |
|------------|------|---------|
| `hp` | `{pid: int}` | current HP (0–100) |
| `lives` | `{pid: int}` | remaining lives (starts at `PLAYER_LIVES = 3`) |
| `kills` | `{pid: int}` | confirmed kills |
| `effects` | `{pid: {name: float}}` | active status effects and their remaining duration |
| `respawning` | `{pid: bool}` | true while the respawn timer runs |

### Damage and death flow

```
damage_player(victim, amount, attacker)
  → hp[victim] -= amount
  → if hp == 0: _player_died(victim)
       → lives[victim] -= 1
       → hp[victim] = MAX_HP   (reset immediately)
       → respawning[victim] = true, timer = RESPAWN_DELAY (2 s)
       → credit kill to last attacker
       → _check_win()
```

### Win conditions (checked after every death)

- Any player reaches `KILLS_TO_WIN = 3` kills → that player wins.
- Only one player has `lives > 0` → that player wins.
- All players reach 0 lives simultaneously → no winner (`is_playing = false`).

### Status effects

`_tick_effects` runs every `_process` frame, decrementing effect timers
and removing expired ones. The effect names are strings (e.g. `"freeze"`,
`"glue"`, `"cage"`); the client applies the visual/movement consequences
based on what `ServerPlayer` sends via RPCs.

---

## 6. ServerPlayer

One `ServerPlayer` node per connected peer. It:

- Is added to the `"players"` group (used by `TrapManager` for proximity checks).
- Has `multiplayer_authority = peer_id`, so only that peer's client can call
  `_net_pos` on it.
- Stores `position` (world) and `rotation.y`, updated by the client's authority
  broadcast each frame.
- `get_grid_position()` converts world position → grid cell for trap activation.

The server never simulates movement — it trusts the authoritative client's
position reports. Anti-cheat is out of scope for the current implementation.

---

## 7. TrapManager

Stores placed traps as:

```
_traps: { "col,row" -> { "owner_pid": int, "type": int } }
```

`net_place_trap(cell, owner_pid, trap_type)` is an `@rpc("any_peer", "call_local")`
RPC — the client calls it on the server; the server records the trap and the
same RPC replicates to all clients so they render the trap visuals.

Trap activation logic (collision detection, area effects, applying damage via
`game_manager.damage_player`) runs on the client that owns each trap. The
server records placements for bookkeeping; effects are applied through the
`GameManager.net_damage` RPC which is authoritative.

---

## 8. Voice relay (VoiceManager)

### Two transport modes

| Mode | When active | Plane |
|------|------------|-------|
| **WebRTC DataChannel** | `USE_WEBRTC = true` AND DataChannel is `STATE_OPEN` | UDP unreliable DataChannel per peer |
| **WebSocket relay fallback** | DataChannel not yet open, or `USE_WEBRTC = false` | rides the gameplay TCP/wss RPC channel |

Both modes use a **star topology** — every peer talks to/from the server;
there is no direct P2P connection between clients (no IP exposure).

### WebRTC signaling flow

```
client                          server (VoiceManager)
  |-- _rpc_voice_offer(sdp) -->|
  |                             |-- _ensure_pc(pid): create WebRTCPeerConnection
  |                             |                    create DataChannel id=1
  |                             |-- pc.set_remote_description("offer", sdp)
  |                             |-- [session_description_created signal]
  |                             |-- pc.set_local_description("answer", ...)
  |<-- _rpc_voice_answer(sdp) --|
  |                             |
  |<-- _rpc_voice_ice(...) -----|  (trickle ICE, both directions)
  |--- _rpc_voice_ice(...) -->--|
  |                             |
  [DataChannel STATE_OPEN]      [DataChannel STATE_OPEN]
```

ICE: uses Google STUN (`stun:stun.l.google.com:19302`). No TURN server is
configured — the server IS the relay, so no TURN is needed.

DataChannel settings: `negotiated=true`, `id=1`, `ordered=false`,
`maxRetransmits=0` (unreliable, unordered — audio tolerates loss, not delay).

### _process loop (per frame)

```
for each WebRTCPeerConnection:  pc.poll()
for each open DataChannel:
    if backlog > MAX_CH_BACKLOG_PKTS (12):
        drop oldest packets  (real-time freshness over completeness)
    read up to MAX_IN_PKTS_PER_PEER_PER_FRAME (6) packets
    for each valid packet (8–1200 bytes):
        _forward(sender_id, audio)
```

### _forward (relay to all other peers)

```
framed packet = [sender_id: i32 little-endian][ADPCM payload]
for each peer != sender:
    if peer's DataChannel is STATE_OPEN:
        ch.put_packet(framed)
    else:
        _rpc_play_voice.rpc_id(peer, audio, sender_id)  # WebSocket fallback
```

The server relays bytes **opaquely** — no decode/re-encode. Codec changes
need no server update.

### WebSocket relay path (fallback / no WebRTC)

`_rpc_voice(audio_bytes, sender_id)` is an `@rpc("any_peer", "unreliable")`
method. When a client sends audio over the RPC channel, the server calls
`_rpc_play_voice.rpc(audio_bytes, sender_id)` to broadcast to all clients.

### Rate limiting / abuse protection

| Constant | Value | Purpose |
|----------|-------|---------|
| `MIN_VOICE_PACKET_BYTES` | 8 | drop suspiciously small packets |
| `MAX_VOICE_PACKET_BYTES` | 1200 | drop oversized packets (MTU-friendly cap) |
| `MAX_IN_PKTS_PER_PEER_PER_FRAME` | 6 | budget per peer per frame to avoid stalls |
| `MAX_CH_BACKLOG_PKTS` | 12 | drop-old strategy when a channel backlog grows |

---

## 9. Deployment

### webrtc-native GDExtension

The server headless binary requires the `webrtc-native` GDExtension to use
`WebRTCPeerConnection`. Without it the class is a non-functional stub (the web
client has WebRTC built in; server does not). The compiled `.so` is in
`addons/webrtc/lib/` which is git-ignored (large binary). `deploy.ps1` copies
it to the VM. `addons/webrtc/webrtc.gdextension` IS tracked in git.

### Build command

```powershell
$GODOT = "C:\Users\XDGT0500\Downloads\Godot_v4.6.3-stable_win64.exe"
# Import first to register the GDExtension into the resource filesystem
& $GODOT --headless --path "C:\work\game\trapbattle-server" --import
& $GODOT --headless --path "C:\work\game\trapbattle-server" --export-release "Linux" "export/linux/TrapBattle Server.x86_64"
```

Exit code 0 with no parse errors = good to deploy.

### deploy.ps1 (git-ignored)

Copies the Linux binary and `addons/webrtc/lib/` to the Azure VM via SCP,
then SSHs in to `systemctl restart trapbattle-server`. Contains plaintext
credentials — never commit it.

---

## 10. Pitfalls and invariants

- **RPC alignment** (§3) — the most common silent failure. Server and client
  must have the exact same `@rpc` method set, in the same alphabetical order,
  on every shared class. Stubs are mandatory.
- **VoiceManager must be created before `lobby_ready`** so that voice RPCs
  arriving from a connecting client are already routed to the right node path
  (`Main/VoiceManager`).
- **`USE_WEBRTC` must match in both repos** (client `voice_manager.gd` and
  server `voice_relay.gd`). Setting it to `true` on one side only will cause
  the signaling RPCs to be sent but never answered.
- **Headless export must pass (exit 0)** before any deploy — required gate
  (also catches GDScript parse errors that `--import` alone may miss).
- **GDScript `:=` on untyped values** infers `Variant` → warning-as-error.
  Use `var x: Type = ...` on anything sourced from an untyped `Array`,
  `Dictionary`, or `Node` property.
- **Tabs, not spaces** — GDScript is tab-sensitive; mixed indentation silently
  breaks an entire class file.
