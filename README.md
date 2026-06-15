# TrapBattle — Dedicated Server

Headless Godot 4.6.3 server for TrapBattle.  
Manages the lobby, maze seed, player state, traps, and voice relay.  
Deployed on an Azure VM behind a Caddy TLS reverse proxy.

---

## Project structure

```
trapbattle-server/
├── project.godot          # Godot project config (headless server)
├── export_presets.cfg     # Export preset: "Linux" → export/linux/
├── deploy.ps1             # Build-and-deploy script (SSH to Azure VM)
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
| Godot | 4.6.3 stable (`Godot_v4.6.3-stable_win64.exe`) |
| OpenSSH client | Ships with Windows 10+; used by `deploy.ps1` |
| Azure VM | Ubuntu 22.04, `172.174.208.254` — NSG must allow 22, 80, 443, 9999 |
| Caddy | v2 on VM, configured as TLS reverse proxy (see below) |

---

## How to export (Linux)

```powershell
$GODOT = "C:\Users\XDGT0500\Downloads\Godot_v4.6.3-stable_win64.exe"
& $GODOT --headless --path "C:\work\game\trapbattle-server" --export-release "Linux" "export/linux/TrapBattle Server.x86_64"
```

Output: `export/linux/TrapBattle Server.x86_64` (+ `.pck` if not embedded).  
The `export/` directory is git-ignored.

---

## How to deploy to the VM

After exporting, copy the binary to the VM and restart the server:

```powershell
$IP   = "172.174.208.254"
$USER = "labadmin"

# Copy binary (and .pck if separate)
scp "export\linux\TrapBattle Server.x86_64" "${USER}@${IP}:/home/labadmin/TrapBattle_Server"
scp "export\linux\TrapBattle Server.pck"    "${USER}@${IP}:/home/labadmin/TrapBattle_Server.pck"

# Restart
ssh "${USER}@${IP}" "pkill -f TrapBattle_Server; chmod +x ~/TrapBattle_Server; setsid nohup ~/TrapBattle_Server --headless < /dev/null > ~/trapserver.log 2>&1 &"
```

Tail logs: `ssh labadmin@172.174.208.254 'tail -f ~/trapserver.log'`

---

## How to run locally (for development)

```powershell
$GODOT = "C:\Users\XDGT0500\Downloads\Godot_v4.6.3-stable_win64.exe"
& $GODOT --headless --path "C:\work\game\trapbattle-server"
```

The server binds to `127.0.0.1:9998` (plain WebSocket, no TLS).  
To test from a local client, point `lobby_ui.gd` at `localhost` and use `ws://` instead of `wss://`.

---

## Production architecture (Azure VM)

```
Browser / itch.io embed
        │  wss://172-174-208-254.nip.io  (port 443)
        ▼
  ┌─────────────────────────────────────────┐
  │  Caddy  (systemd service, auto TLS)     │
  │  /etc/caddy/Caddyfile                   │
  │  • terminates TLS (Let's Encrypt cert)  │
  │  • forces HTTP/1.1 (protocols h1)       │
  │  • reverse_proxy → 127.0.0.1:9998      │
  └─────────────────────────────────────────┘
        │  ws://127.0.0.1:9998  (plain, loopback only)
        ▼
  Godot headless server  (nohup, NOT systemd — does not survive reboot)
```

### Caddy configuration (`/etc/caddy/Caddyfile` on VM)

```caddy
{
    email jaber.yacine@gmail.com
    servers {
        protocols h1
    }
}

172-174-208-254.nip.io, 172-174-208-254.nip.io:9999 {
    log {
        output file /var/log/caddy/access.log
        level INFO
    }
    reverse_proxy 127.0.0.1:9998
}
```

`protocols h1` is **required** — without it Caddy negotiates HTTP/2, and Firefox sends WebSocket upgrades over HTTP/2 Extended CONNECT which Godot's WS server rejects ("Missing or invalid header 'upgrade'").

`nip.io` provides wildcard DNS: `172-174-208-254.nip.io` resolves to `172.174.208.254`, letting Let's Encrypt issue a real cert for the IP.

After editing the Caddyfile on the VM: `sudo systemctl reload caddy`

---

## Known limitations

- **Godot process is not a systemd service** — it will not restart on VM reboot. After a reboot, run `deploy.ps1` again (or SSH in and start it manually). Converting to a systemd unit is a planned improvement.
- **VM is Azure B1s in eastus** — 1 vCPU, ~1 GB RAM, US East region. French/EU players experience ~90 ms transatlantic latency plus CPU contention from simultaneous Godot physics + Caddy + voice relay. Upsizing to B2s and moving to West Europe / France Central will significantly reduce lag.
