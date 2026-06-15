extends Node
class_name VoiceManager

# Minimal voice relay that runs on the dedicated server.
# Clients send _rpc_voice here; the server rebroadcasts via _rpc_play_voice.
# The node MUST be named "VoiceManager" and added at path "Main/VoiceManager"
# so Godot's RPC routing resolves the same node path as on the client.

## Client → server: receive audio and relay to all other clients.
@rpc("any_peer", "call_remote", "unreliable")
func _rpc_voice(audio_bytes: PackedByteArray, sender_id: int) -> void:
	_rpc_play_voice.rpc(audio_bytes, sender_id)

## Server → all clients: MUST match the client decorator exactly.
@rpc("authority", "call_remote", "unreliable")
func _rpc_play_voice(_audio_bytes: PackedByteArray, _sender_id: int) -> void:
	pass   # stub — runs on clients only
