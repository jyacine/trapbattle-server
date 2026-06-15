# TrapBattle — Dedicated Server

Headless Godot 4.6.3 server for TrapBattle.  
Manages the lobby, maze seed, player state, traps, and voice relay.

---

## Project structure

```
trapbattle-server/
├── project.godot          # Godot project config (headless server)
├── export_presets.cfg     # Export preset: "Linux" → export/linux/
├── scenes/
│   └── Main.tscn          # Root scene — instantiates all managers
└── scripts/
    ├── config.gd          # Autoload — shared constants (port, max players)
    ├── main.gd            # Entry point: starts NetworkManager, VoiceManager,
    │                      #   and spawns GameManager / TrapManager on lobby_ready
    ├── network_manager.gd # WebSocket server (plain ws, 127.0.0.1:9998),
    │                      #   lobby countdown, RPC dispatch
    ├── game_manager.gd    # HP, lives, kills, respawn, death/win conditions
    ├── trap_manager.gd    # Trap ownership and activation relay
    ├── maze_generator.gd  # Procedural maze (same algorithm as client — seed synced)
    ├── server_player.gd   # Per-peer authoritative state (position, health tick)
    └── voice_relay.gd     # VoiceManager — relays PCM packets between peers
```

---

## Prerequisites

| Tool | Version / notes |
|------|----------------|
| Godot | 4.6.3 stable |

---

## How to export (Linux)

```powershell
$GODOT = "<path to Godot executable>"
& $GODOT --headless --path "<path to trapbattle-server>" --export-release "Linux" "export/linux/TrapBattle Server.x86_64"
```

Output: `export/linux/TrapBattle Server.x86_64` (+ `.pck` if not embedded).  
The `export/` directory is git-ignored.

---

## How to deploy

After exporting, copy the binary to your server and start it headless:

```bash
# On the server
chmod +x TrapBattle_Server
nohup ./TrapBattle_Server --headless > trapserver.log 2>&1 &
```

The server binds to `127.0.0.1:9998` (plain WebSocket).  
Put a TLS-terminating reverse proxy (e.g. Caddy or nginx) in front of it so browser clients can connect via `wss://`.

### Caddy example (`/etc/caddy/Caddyfile`)

```caddy
{
    servers {
        protocols h1
    }
}

your.domain.com {
    reverse_proxy 127.0.0.1:9998
}
```

> `protocols h1` is required — without it Firefox sends WebSocket upgrades over HTTP/2 which Godot rejects.

---

## How to run locally (for development)

```powershell
$GODOT = "<path to Godot executable>"
& $GODOT --headless --path "<path to trapbattle-server>"
```

The server listens on `127.0.0.1:9998` (plain WebSocket, no TLS).  
To connect from a local client, point `lobby_ui.gd` at `localhost` and use `ws://` instead of `wss://`.
