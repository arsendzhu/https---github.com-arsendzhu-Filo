class_name RoundedBoxMesh
extends RefCounted
## Procedural soft-edged cube. Each face is a subdivided grid; every vertex on
## the sharp cube is pushed onto the rounded-box surface:
##   q = clamp(p, -(h - r), h - r)      (nearest point on the inner box)
##   p' = q + r * normalize(p - q)      (offset by the corner radius)
## which leaves flat faces flat and rounds edges and corners with correct normals.
## Samples are biased toward the edges so the rounding gets more triangles.


static func build(size: float = 1.0, radius: float = 0.18, subdiv: int = 12) -> ArrayMesh:
	var h := size * 0.5
	radius = clampf(radius, 0.0, h)
	var inner := h - radius
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# [normal, u axis, v axis] with u x v = normal (right-handed)
	var faces := [
		[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
		[Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)],
		[Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)],
		[Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
		[Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)],
		[Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
	]
	for face in faces:
		var n: Vector3 = face[0]
		var u: Vector3 = face[1]
		var v: Vector3 = face[2]
		var base := verts.size()
		for j in range(subdiv + 1):
			var tv := _bias(float(j) / float(subdiv))
			for i in range(subdiv + 1):
				var tu := _bias(float(i) / float(subdiv))
				var p := n * h + u * ((tu * 2.0 - 1.0) * h) + v * ((tv * 2.0 - 1.0) * h)
				var q := Vector3(clampf(p.x, -inner, inner), clampf(p.y, -inner, inner), clampf(p.z, -inner, inner))
				var d := p - q
				var nn := d.normalized() if d.length() > 1e-6 else n
				verts.append(q + nn * radius)
				normals.append(nn)
				uvs.append(Vector2(tu, 1.0 - tv))
		for j in range(subdiv):
			for i in range(subdiv):
				var a := base + j * (subdiv + 1) + i
				var b := a + 1
				var c := a + (subdiv + 1) + 1
				var d2 := a + (subdiv + 1)
				# Godot's front faces wind clockwise when seen from outside
				indices.append(a)
				indices.append(c)
				indices.append(b)
				indices.append(a)
				indices.append(d2)
				indices.append(c)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Pushes grid samples toward the face edges (where the rounding happens).
static func _bias(t: float) -> float:
	var s := t * 2.0 - 1.0
	var e := signf(s) * pow(absf(s), 0.72)
	return clampf(e * 0.5 + 0.5, 0.0, 1.0)
