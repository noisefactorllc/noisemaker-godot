# resources.gd — liveness analysis + linear-scan texture pooling. Port of TD
# compiler/graph/resources.py (1:1 with hlsl Resources.cs / shaders/src/runtime/resources.js,
# reference/04 §1).
#
# allocate_resources(passes) maps virtual pooled texIds -> physical slots "phys_N" (the producer
# of RenderGraph.allocations). PARITY-CRITICAL (reference/04 §1.3): output allocation (insertion
# order of pass.outputs values) happens BEFORE input release (pass.inputs values) within a pass;
# the free-slot search picks the FIRST freeList entry with availableAfter < i; only 'global_' ids
# are excluded (infinite-lived). Fully deterministic, no float math.
extends RefCounted

static func _touch(lifetime: Dictionary, tex_id, index: int) -> void:
	if tex_id == null or tex_id == "":
		return
	if (tex_id as String).begins_with("global_"):
		return
	if not lifetime.has(tex_id):
		lifetime[tex_id] = [index, index]
	else:
		var l: Array = lifetime[tex_id]
		if index < l[0]:
			l[0] = index
		if index > l[1]:
			l[1] = index

static func _analyze_liveness(passes: Array) -> Dictionary:
	var lifetime := {}  # texId -> [start, end]
	for index in range(passes.size()):
		var p: Dictionary = passes[index]
		var inputs = p.get("inputs")
		if inputs != null:
			for tex in inputs.values():
				_touch(lifetime, tex, index)
		var outputs = p.get("outputs")
		if outputs != null:
			for tex in outputs.values():
				_touch(lifetime, tex, index)
	return lifetime

static func allocate_resources(passes: Array) -> Dictionary:
	var lifetime := _analyze_liveness(passes)
	var allocations := {}     # texId -> "phys_N" (insertion-ordered)
	var free_list: Array = [] # list of [phys_id, available_after]
	var physical_count := 0

	for i in range(passes.size()):
		var p: Dictionary = passes[i]
		# 1. allocate outputs (definitions)
		var outputs = p.get("outputs")
		if outputs != null:
			for tex_id in outputs.values():
				if tex_id == null:
					continue
				if (tex_id as String).begins_with("global_"):
					continue
				if allocations.has(tex_id):
					continue
				var free_idx := -1
				for k in range(free_list.size()):
					if free_list[k][1] < i:
						free_idx = k
						break
				if free_idx != -1:
					var phys_id = free_list[free_idx][0]
					free_list.remove_at(free_idx)
					allocations[tex_id] = phys_id
				else:
					allocations[tex_id] = "phys_%d" % physical_count
					physical_count += 1

		# 2. release inputs (last uses)
		var inputs = p.get("inputs")
		if inputs != null:
			for tex_id in inputs.values():
				if tex_id == null:
					continue
				if (tex_id as String).begins_with("global_"):
					continue
				if lifetime.has(tex_id):
					var l: Array = lifetime[tex_id]
					if l[1] == i:
						if allocations.has(tex_id):
							free_list.append([allocations[tex_id], i])
	return allocations
