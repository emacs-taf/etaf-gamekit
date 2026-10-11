extends Node
## Public Godot SDK fixture: an autonomous clock, controlled through commands.
## SPDX-License-Identifier: GPL-3.0-or-later
var seconds := 0.0
var running := false

func _physics_process(delta: float) -> void:
	if running:
		seconds += delta

func capabilities() -> Array:
	return ["run"]

func command(operation: String, _args: Dictionary) -> String:
	if operation != "run":
		return "Unknown clock action"
	seconds = 0.0
	running = true
	return ""

func observe() -> Dictionary:
	return {"seconds": seconds, "running": running}
