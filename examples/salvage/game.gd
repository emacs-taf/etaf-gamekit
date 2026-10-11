extends Node2D
## A small real-time salvage game. Godot owns motion, collision and path search.
## SPDX-License-Identifier: GPL-3.0-or-later

const WIDTH := 32
const HEIGHT := 18
const DOCK := Vector2i(3, 14)
const CORE_POSITIONS := [Vector2i(12, 3), Vector2i(26, 4), Vector2i(26, 14)]
const ENEMY_POSITIONS := [Vector2i(16, 4), Vector2i(25, 9), Vector2i(18, 14)]

class Unit extends CharacterBody2D:
	var route: Array[Vector2i] = []
	var speed := 4.0
	var identity := ""
	var stopped := false
	func _physics_process(delta: float) -> void:
		if stopped or route.is_empty():
			velocity = Vector2.ZERO
			return
		var target := Vector2(route[0]) + Vector2(0.5, 0.5)
		var difference := target - position
		if difference.length() <= speed * delta:
			position = target
			route.pop_front()
			velocity = Vector2.ZERO
		else:
			velocity = difference.normalized() * speed
			move_and_slide()

var navigation := AStarGrid2D.new()
var terrain: Array[String] = []
var player: Unit
var enemies: Array[Unit] = []
var cores: Array = []
var log_entries: Array = []
var health := 100.0
var energy := 100.0
var score := 0
var repairs := 2
var paused := true
var won := false
var seconds := 0.0
var pulse_cooldown := 0.0
var shield_remaining := 0.0
var hurt_cooldown := 0.0
var ai_clock := 0.0
var pulse_flash := 0.0
var event_id := 0

func _ready() -> void:
	navigation.region = Rect2i(0, 0, WIDTH, HEIGHT)
	navigation.cell_size = Vector2.ONE
	navigation.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	navigation.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	navigation.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	navigation.update()
	for y in HEIGHT:
		var row := ""
		for x in WIDTH:
			var solid := x == 0 or y == 0 or x == WIDTH - 1 or y == HEIGHT - 1
			solid = solid or (x == 9 and y not in [4, 13]) or (x == 21 and y not in [5, 12])
			solid = solid or (y == 8 and x not in [4, 5, 15, 16, 26, 27])
			row += "#" if solid else "."
			if solid:
				navigation.set_point_solid(Vector2i(x, y), true)
				var wall := StaticBody2D.new()
				wall.position = Vector2(x + 0.5, y + 0.5)
				wall.collision_layer = 1
				wall.collision_mask = 2
				var shape := CollisionShape2D.new()
				var rectangle := RectangleShape2D.new()
				rectangle.size = Vector2.ONE
				shape.shape = rectangle
				wall.add_child(shape)
				add_child(wall)
		terrain.append(row)
	_reset()

func _unit(identity: String, at: Vector2i, speed: float) -> Unit:
	var unit := Unit.new()
	unit.identity = identity
	unit.position = Vector2(at) + Vector2(0.5, 0.5)
	unit.speed = speed
	unit.collision_layer = 2
	unit.collision_mask = 1
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 0.28
	shape.shape = circle
	unit.add_child(shape)
	add_child(unit)
	return unit

func _reset() -> void:
	if is_instance_valid(player):
		player.free()
	for enemy in enemies:
		enemy.free()
	enemies.clear()
	player = _unit("pilot", Vector2i(4, 4), 7.0)
	for index in ENEMY_POSITIONS.size():
		enemies.append(_unit("drone-" + str(index + 1), ENEMY_POSITIONS[index], 1.4 + index * 0.2))
	cores = [false, false, false]
	health = 100.0
	energy = 100.0
	score = 0
	repairs = 2
	seconds = 0.0
	pulse_cooldown = 0.0
	shield_remaining = 0.0
	hurt_cooldown = 0.0
	ai_clock = 0.0
	paused = true
	won = false
	pulse_flash = 0.0
	event_id = 0
	log_entries = []
	_event("Welcome aboard", "Recover 3 cores, then return to the extraction dock.", "info")
	_event("Tactical pause", "Press P or Launch to begin. Click a deck tile to navigate.", "info")
	_set_stopped()

func _event(title: String, detail: String, kind: String) -> void:
	event_id += 1
	log_entries.push_front({"id": event_id, "title": title, "detail": detail, "kind": kind, "time": int(seconds)})
	if log_entries.size() > 12:
		log_entries.pop_back()

func _cell(unit: Unit) -> Vector2i:
	return Vector2i(floor(unit.position.x), floor(unit.position.y))

func _set_stopped() -> void:
	player.stopped = paused or won or health <= 0
	for enemy in enemies:
		enemy.stopped = player.stopped

func _route(unit: Unit, target: Vector2i) -> bool:
	if not navigation.is_in_boundsv(target) or navigation.is_point_solid(target):
		return false
	var path := navigation.get_id_path(_cell(unit), target)
	if path.is_empty():
		return false
	path.pop_front()
	unit.route = path
	return true

func _physics_process(delta: float) -> void:
	if paused or won or health <= 0:
		return
	seconds += delta
	energy = minf(100, energy + delta * 1.8)
	pulse_cooldown = maxf(0, pulse_cooldown - delta)
	shield_remaining = maxf(0, shield_remaining - delta)
	hurt_cooldown = maxf(0, hurt_cooldown - delta)
	pulse_flash = maxf(0, pulse_flash - delta)
	ai_clock -= delta
	if ai_clock <= 0:
		ai_clock = 0.7
		for enemy in enemies:
			var target: Vector2i = _cell(player) if enemy.position.distance_to(player.position) < 12 else ENEMY_POSITIONS[int(enemy.identity.right(1)) - 1]
			_route(enemy, target)
	for index in cores.size():
		if not cores[index] and player.position.distance_to(Vector2(CORE_POSITIONS[index]) + Vector2(0.5, 0.5)) < 0.65:
			cores[index] = true
			score += 150
			_event("Core recovered", "Power core %d secured in cargo." % (index + 1), "success")
	for enemy in enemies:
		if hurt_cooldown <= 0 and enemy.position.distance_to(player.position) < 0.85:
			hurt_cooldown = 1.0
			if shield_remaining <= 0:
				health = maxf(0, health - 12)
				_event("Hull impact", "A security drone dealt 12 damage.", "danger")
	if cores.all(func(value): return value) and player.position.distance_to(Vector2(DOCK) + Vector2(0.5, 0.5)) < 0.65:
		won = true
		score += 300
		_event("Extraction complete", "All three cores recovered. Station secured.", "success")
	if won or health <= 0:
		_set_stopped()

func capabilities() -> Array:
	return ["move", "navigate", "pulse", "shield", "repair", "pause", "restart", "save", "load"]

func command(operation: String, args: Dictionary) -> String:
	if operation == "restart":
		_reset()
		return ""
	if operation == "pause":
		if won or health <= 0:
			return "This expedition has ended. Start a new run."
		paused = not paused
		_set_stopped()
		return ""
	if operation in ["save", "load"]:
		if not args.get("path") is String or args.path.is_empty():
			return "A snapshot path is required"
		return _save(args.path) if operation == "save" else _restore(args.path)
	if won or health <= 0:
		return "This expedition has ended. Start a new run."
	match operation:
		"move", "navigate":
			for key in ["x", "y"]:
				if not args.get(key) is float or not is_finite(args[key]) or args[key] != floor(args[key]):
					return "Coordinates must be integers"
			var target: Vector2i
			if operation == "move":
				var direction := Vector2i(int(args.get("x", 0)), int(args.get("y", 0)))
				if absi(direction.x) + absi(direction.y) != 1:
					return "Move requires one cardinal direction"
				target = (player.route.back() if not player.route.is_empty() else _cell(player)) + direction
			else:
				target = Vector2i(int(args.get("x", -1)), int(args.get("y", -1)))
			if not _route(player, target):
				return "That deck tile is blocked"
		"pulse":
			if paused:
				return "Resume the expedition before using a skill"
			if pulse_cooldown > 0 or energy < 20:
				return "Pulse needs 20 energy and a ready cooldown"
			energy -= 20
			pulse_cooldown = 4.0
			pulse_flash = 0.5
			var hits := 0
			for index in range(enemies.size() - 1, -1, -1):
				if enemies[index].position.distance_to(player.position) <= 5:
					enemies[index].free()
					enemies.remove_at(index)
					hits += 1
			score += hits * 75
			_event("Pulse discharged", "%d drones disabled within 5 tiles." % hits, "success")
		"shield":
			if energy < 25:
				return "Shield needs 25 energy"
			energy -= 25
			shield_remaining = 5.0
			_event("Shield online", "Hull protected for 5 seconds.", "info")
		"repair":
			if health >= 100:
				return "Hull is already intact"
			if repairs <= 0:
				return "No repair kits remaining"
			repairs -= 1
			health = minf(100, health + 40)
			_event("Hull repaired", "One repair kit restored up to 40 hull.", "success")
		_:
			return "Unsupported action: " + operation
	return ""

func observe() -> Dictionary:
	var entities: Array = [{"id": "pilot", "name": "Surveyor R-07", "kind": "pilot", "x": _cell(player).x, "y": _cell(player).y}]
	for enemy in enemies:
		entities.append({"id": enemy.identity, "name": "Security " + enemy.identity, "kind": "drone", "x": _cell(enemy).x, "y": _cell(enemy).y})
	for index in cores.size():
		if not cores[index]:
			entities.append({"id": "core-" + str(index + 1), "name": "Power core " + str(index + 1), "kind": "core", "x": CORE_POSITIONS[index].x, "y": CORE_POSITIONS[index].y})
	entities.append({"id": "dock", "name": "Extraction dock", "kind": "dock", "x": DOCK.x, "y": DOCK.y})
	var path: Array = []
	for point in player.route:
		path.append([point.x, point.y])
	return {"schema": "salvage/1", "title": "Salvage Station",
		"world": {"width": WIDTH, "height": HEIGHT, "terrain": terrain, "entities": entities, "route": path,
			"pulse": pulse_flash > 0, "shield": shield_remaining > 0},
		"pilot": {"health": int(ceil(health)), "energy": int(energy), "repairs": repairs, "cores": cores.count(true),
			"score": score, "pulse_cooldown": int(ceil(pulse_cooldown)), "shield_remaining": int(ceil(shield_remaining))},
		"mission": {"paused": paused, "won": won, "lost": health <= 0, "seconds": int(seconds), "drones": enemies.size()},
		"events": log_entries}

func _save(path: String) -> String:
	if path.is_empty():
		return "A snapshot path is required"
	var positions: Array = []
	for enemy in enemies:
		positions.append({"id": enemy.identity, "x": enemy.position.x, "y": enemy.position.y})
	var data := {"format": "salvage/1", "x": player.position.x, "y": player.position.y,
		"health": health, "energy": energy, "score": score, "repairs": repairs, "cores": cores,
		"seconds": seconds, "enemies": positions, "events": log_entries,
		"pulse_cooldown": pulse_cooldown, "shield_remaining": shield_remaining, "won": won}
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		return "Cannot write snapshot: " + error_string(FileAccess.get_open_error())
	file.store_string(JSON.stringify(data))
	file.close()
	var result := DirAccess.rename_absolute(path + ".tmp", path)
	return "" if result == OK else "Cannot publish snapshot: " + error_string(result)

func _restore(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "Cannot read snapshot"
	if file.get_length() > 1024 * 1024:
		return "Snapshot exceeds 1 MiB"
	var decoder := JSON.new()
	if decoder.parse(file.get_as_text()) != OK:
		return "Invalid snapshot JSON"
	var data = decoder.data
	if not data is Dictionary or data.get("format") != "salvage/1":
		return "Incompatible snapshot"
	for key in ["x", "y", "health", "energy", "score", "repairs", "seconds", "pulse_cooldown", "shield_remaining"]:
		if not data.get(key) is float or not is_finite(data[key]):
			return "Invalid numeric snapshot field: " + key
	if not data.get("cores") is Array or data.cores.size() != 3 or not data.cores.all(func(value): return value is bool):
		return "Invalid cargo snapshot"
	if not data.get("enemies") is Array or data.enemies.size() > 3 or not data.get("events") is Array or not data.get("won") is bool:
		return "Invalid expedition snapshot"
	if data.health < 0 or data.health > 100 or data.energy < 0 or data.energy > 100 or data.repairs < 0 or data.repairs > 2 or data.repairs != floor(data.repairs):
		return "Snapshot resources are out of range"
	if data.score < 0 or data.score > 975 or data.score != floor(data.score) or data.seconds < 0 or data.pulse_cooldown < 0 or data.pulse_cooldown > 4 or data.shield_remaining < 0 or data.shield_remaining > 5:
		return "Snapshot progress is out of range"
	if data.won and (not data.cores.all(func(value): return value) or data.health <= 0):
		return "Invalid completed expedition"
	if not _position_valid(data.x, data.y):
		return "Snapshot pilot is outside the deck"
	var identities: Array = []
	for enemy in data.enemies:
		if not enemy is Dictionary or not enemy.get("id") in ["drone-1", "drone-2", "drone-3"] or enemy.id in identities or not enemy.get("x") is float or not enemy.get("y") is float or not _position_valid(enemy.x, enemy.y):
			return "Invalid drone snapshot"
		identities.append(enemy.id)
	if data.events.size() > 12:
		return "Too many snapshot events"
	var previous_id := INF
	var maximum_id := 0
	for event in data.events:
		if not event is Dictionary or not event.get("id") is float or not is_finite(event.id) or event.id < 1 or event.id != floor(event.id) or event.id >= previous_id:
			return "Invalid snapshot event identity"
		if not event.get("time") is float or not is_finite(event.time) or event.time < 0 or event.time != floor(event.time) or event.time > data.seconds:
			return "Invalid snapshot event time"
		if not event.get("title") is String or event.title.length() > 256 or not event.get("detail") is String or event.detail.length() > 2048 or not event.get("kind") in ["info", "success", "danger"]:
			return "Invalid snapshot event content"
		previous_id = event.id
		maximum_id = maxi(maximum_id, int(event.id))

	_reset()
	player.position = Vector2(data.x, data.y)
	for enemy in enemies:
		enemy.free()
	enemies.clear()
	for enemy in data.enemies:
		var unit := _unit(enemy.id, Vector2i.ZERO, 1.4 + (int(enemy.id.right(1)) - 1) * 0.2)
		unit.position = Vector2(enemy.x, enemy.y)
		enemies.append(unit)
	health = data.health
	energy = data.energy
	score = int(data.score)
	repairs = int(data.repairs)
	cores = data.cores
	seconds = data.seconds
	pulse_cooldown = data.pulse_cooldown
	shield_remaining = data.shield_remaining
	won = data.won
	log_entries = data.events
	for event in log_entries:
		event.id = int(event.id)
		event.time = int(event.time)
	event_id = maximum_id
	paused = true
	_event("Snapshot restored", "Expedition restored in tactical pause.", "info")
	_set_stopped()
	return ""

func _position_valid(x: float, y: float) -> bool:
	if not is_finite(x) or not is_finite(y) or x < 1 or y < 1 or x >= WIDTH - 1 or y >= HEIGHT - 1:
		return false
	var center := Vector2(x, y)
	var cell := Vector2i(floor(x), floor(y))
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var tile := cell + Vector2i(dx, dy)
			if navigation.is_point_solid(tile):
				var nearest := Vector2(clampf(x, tile.x, tile.x + 1), clampf(y, tile.y, tile.y + 1))
				if center.distance_squared_to(nearest) < 0.28 * 0.28 - 0.00001:
					return false
	return true
