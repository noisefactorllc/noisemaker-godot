extends SceneTree

const Backend := preload("res://addons/noisemaker/runtime/nm_backend.gd")
const EffectRegistry := preload("res://addons/noisemaker/compiler/lang/effect_registry.gd")
const Orchestrator := preload("res://addons/noisemaker/compiler/graph/orchestrator.gd")


func _fail(message: String) -> void:
	printerr("DEVICE_LIMITS_TEST: ", message)
	quit(1)


func _supports_color_formats(rd: RenderingDevice, formats: Array) -> bool:
	var textures := []
	var supported := true
	for format in formats:
		var usage := RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT
		if not rd.texture_is_format_supported_for_usage(int(format), usage):
			supported = false
			break
		var texture_format := RDTextureFormat.new()
		texture_format.width = 2
		texture_format.height = 2
		texture_format.format = int(format)
		texture_format.usage_bits = usage
		var texture := rd.texture_create(texture_format, RDTextureView.new())
		if not texture.is_valid():
			supported = false
			break
		textures.append(texture)
	var framebuffer := RID()
	if supported:
		framebuffer = rd.framebuffer_create(textures)
	var valid: bool = framebuffer.is_valid() and rd.framebuffer_is_valid(framebuffer)
	if framebuffer.is_valid():
		rd.free_rid(framebuffer)
	for texture in textures:
		if texture.is_valid():
			rd.free_rid(texture)
	return valid


func _detect_color_budget(rd: RenderingDevice) -> int:
	var rgba32f := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	var rgba16f := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	var combinations := [
		{"bytes": 64, "formats": [rgba32f, rgba32f, rgba32f, rgba32f]},
		{"bytes": 48, "formats": [rgba32f, rgba32f, rgba32f]},
		{"bytes": 40, "formats": [rgba32f, rgba32f, rgba16f]},
		{"bytes": 32, "formats": [rgba32f, rgba16f, rgba16f]},
	]
	for combination in combinations:
		if _supports_color_formats(rd, combination["formats"]):
			return int(combination["bytes"])
	return 16


func _init() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		_fail("RenderingDevice unavailable")
		return

	var backend = Backend.new()
	backend.setup(rd, "res://addons/noisemaker", Vector2i(32, 32))
	var reported_texture_limit := int(backend.get("_max_texture_size_2d"))
	var device_texture_limit := rd.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D)
	var probed_color_budget := int(backend.get("_max_color_bytes_per_sample"))
	var detected_color_budget := _detect_color_budget(rd)
	if reported_texture_limit <= 0 or reported_texture_limit != device_texture_limit:
		_fail("texture limit mismatch: backend=%d device=%d" % [
			reported_texture_limit, device_texture_limit,
		])
		return
	if probed_color_budget != detected_color_budget:
		_fail("color attachment budget mismatch: backend=%d detected=%d" % [
			probed_color_budget, detected_color_budget,
		])
		return

	var registry := EffectRegistry.new()
	registry.load_all()
	var source := """search synth, points, render

noise().pointsEmit(stateSize: x8).pointsRender(density: 100).write(o0)

render(o0)
"""
	var graph: Dictionary = Orchestrator.new(registry).build_graph(source)
	backend.render(graph)

	var xyz_format := ""
	var vel_format := ""
	for texture_id in graph.get("textures", {}):
		var format := str(graph["textures"][texture_id].get("format", ""))
		if str(texture_id).begins_with("global_xyz"):
			xyz_format = format
		elif str(texture_id).begins_with("global_vel"):
			vel_format = format
	if probed_color_budget >= 36:
		if (xyz_format != "rgba32f" and xyz_format != "rgba32float") \
				or (vel_format != "rgba32f" and vel_format != "rgba32float"):
			_fail("supported float attachments were unexpectedly demoted: xyz=%s vel=%s" % [
				xyz_format, vel_format,
			])
			return
	else:
		if xyz_format != "rgba32f" and xyz_format != "rgba32float":
			_fail("position attachment was not preserved: %s" % xyz_format)
			return
		if vel_format != "rgba16f":
			_fail("velocity attachment was not demoted: %s" % vel_format)
			return

	var image: Image = backend.call("_snapshot_surface")
	if image == null or image.is_empty() or image.get_size() != Vector2i(32, 32):
		_fail("render snapshot is missing or has the wrong size")
		return
	print("DEVICE_LIMITS_TEST: PASS texture_limit=", reported_texture_limit,
		" probed_color_budget=", probed_color_budget)
	quit(0)
