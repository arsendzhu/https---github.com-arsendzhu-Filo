class_name Mascot
extends Control
## The mascot's rendering pipeline: a tiny SubViewport renders the procedural
## rounded cube (with its shader-drawn face) at a low internal resolution; a
## TextureRect upscales it with nearest-neighbour filtering and applies the
## palette + dither post pass. The MascotAnimator child drives all motion.

const CUBE_SHADER := preload("res://mascot/shaders/cube_face.gdshader")
const POST_SHADER := preload("res://mascot/shaders/psx_post.gdshader")
const SHADOW_SHADER := preload("res://mascot/shaders/shadow_blob.gdshader")

## Limited palette (sRGB): a five-step cream ramp for the body, face ink,
## the screen-reading glint, cheek blush and the contact shadow.
const PALETTE := [
	Vector3(0.964, 0.911, 0.829),
	Vector3(0.945, 0.863, 0.737),
	Vector3(0.813, 0.742, 0.634),
	Vector3(0.680, 0.621, 0.531),
	Vector3(0.548, 0.500, 0.427),
	Vector3(0.169, 0.141, 0.220),
	Vector3(0.700, 0.980, 0.950),
	Vector3(0.950, 0.600, 0.620),
	Vector3(0.230, 0.190, 0.270),
]

var internal_res := 96
var display_pts := 240.0
var pixel_scale := 5
var viewport: SubViewport
var camera: Camera3D
var pivot: Node3D
var cube: MeshInstance3D
var shadow: MeshInstance3D
var display: TextureRect
var cube_mat: ShaderMaterial
var post_mat: ShaderMaterial
var shadow_mat: ShaderMaterial
var animator: MascotAnimator
var _cfg: FiloConfig


## size_pts: desired on-screen size in points; screen_scale: backing scale.
## The display size is rounded so each internal pixel maps to a whole number
## of physical pixels (crisp nearest-neighbour upscale on any display).
func configure(cfg: FiloConfig, screen_scale: float) -> void:
	internal_res = maxi(int(cfg.get_value("mascot.internal_resolution", 96)), 32)
	var wanted_pts: float = float(cfg.get_value("mascot.size", 240))
	pixel_scale = maxi(1, roundi(wanted_pts * screen_scale / internal_res))
	display_pts = internal_res * pixel_scale / screen_scale
	custom_minimum_size = Vector2(display_pts, display_pts)
	size = custom_minimum_size
	_cfg = cfg
	if is_node_ready():
		_apply_config(cfg)


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	viewport = SubViewport.new()
	viewport.size = Vector2i(internal_res, internal_res)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	add_child(viewport)

	var world := Node3D.new()
	world.name = "World"
	viewport.add_child(world)

	camera = Camera3D.new()
	camera.fov = 30.0
	camera.near = 0.1
	camera.far = 20.0
	camera.position = Vector3(0.0, 0.42, 3.05)
	camera.look_at_from_position(camera.position, Vector3(0.0, -0.02, 0.0), Vector3.UP)
	world.add_child(camera)
	camera.current = true

	pivot = Node3D.new()
	pivot.name = "Pivot"
	world.add_child(pivot)

	cube = MeshInstance3D.new()
	cube.name = "Cube"
	cube.mesh = RoundedBoxMesh.build(1.0, 0.18, 12)
	cube_mat = ShaderMaterial.new()
	cube_mat.shader = CUBE_SHADER
	cube.material_override = cube_mat
	pivot.add_child(cube)

	shadow = MeshInstance3D.new()
	shadow.name = "Shadow"
	var quad := QuadMesh.new()
	quad.size = Vector2(1.35, 1.35)
	shadow.mesh = quad
	shadow_mat = ShaderMaterial.new()
	shadow_mat.shader = SHADOW_SHADER
	shadow.material_override = shadow_mat
	shadow.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	shadow.position = Vector3(0.0, -0.57, 0.0)
	world.add_child(shadow)

	display = TextureRect.new()
	display.name = "Display"
	display.texture = viewport.get_texture()
	display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	display.stretch_mode = TextureRect.STRETCH_SCALE
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.mouse_filter = MOUSE_FILTER_IGNORE
	display.set_anchors_preset(Control.PRESET_FULL_RECT)
	post_mat = ShaderMaterial.new()
	post_mat.shader = POST_SHADER
	post_mat.set_shader_parameter("palette", PackedVector3Array(PALETTE))
	post_mat.set_shader_parameter("palette_size", PALETTE.size())
	display.material = post_mat
	add_child(display)

	animator = MascotAnimator.new()
	animator.name = "Animator"
	add_child(animator)
	animator.setup(self)
	set_alpha(0.0)
	if _cfg:
		_apply_config(_cfg)


func _apply_config(cfg: FiloConfig) -> void:
	viewport.size = Vector2i(internal_res, internal_res)
	post_mat.set_shader_parameter("dither", float(cfg.get_value("mascot.dither", 0.09)))
	cube_mat.set_shader_parameter("jitter", float(cfg.get_value("mascot.vertex_jitter", 0.0)))


func set_alpha(a: float) -> void:
	display.modulate.a = clampf(a, 0.0, 1.0)
	display.visible = a > 0.001


func set_shadow(scale_factor: float, strength: float) -> void:
	shadow.scale = Vector3(scale_factor, scale_factor, scale_factor)
	shadow_mat.set_shader_parameter("strength", strength)
	shadow.visible = strength > 0.01


func set_face(face: Dictionary, eye_open: float, mouth_open: float, glint_on: bool) -> void:
	cube_mat.set_shader_parameter("eye_center", face.get("eye_center", Vector2(0.40, 0.08)))
	cube_mat.set_shader_parameter("eye_size", face.get("eye_size", Vector2(0.24, 0.20)))
	cube_mat.set_shader_parameter("eye_open", clampf(eye_open, 0.0, 1.3))
	cube_mat.set_shader_parameter("eye_shift", face.get("eye_shift", Vector2.ZERO))
	cube_mat.set_shader_parameter("eye_style", int(face.get("eye_style", 0)))
	cube_mat.set_shader_parameter("eye_highlight", float(face.get("eye_highlight", 0.07)))
	cube_mat.set_shader_parameter("eye_asym", face.get("eye_asym", Vector2.ONE))
	cube_mat.set_shader_parameter("mouth_style", int(face.get("mouth_style", 0)))
	cube_mat.set_shader_parameter("mouth_x", float(face.get("mouth_x", 0.0)))
	cube_mat.set_shader_parameter("mouth_y", float(face.get("mouth_y", -0.26)))
	cube_mat.set_shader_parameter("mouth_width", float(face.get("mouth_width", 0.11)))
	cube_mat.set_shader_parameter("mouth_open", clampf(mouth_open, 0.0, 1.0))
	cube_mat.set_shader_parameter("mouth_curve", float(face.get("mouth_curve", 0.12)))
	cube_mat.set_shader_parameter("blush", clampf(float(face.get("blush", 0.0)), 0.0, 1.0))
	cube_mat.set_shader_parameter("glint", 1.0 if glint_on else 0.0)
	if glint_on:
		# screen-reading cue: the shine dots turn cyan and twinkle between 1 and 2 px
		var tw := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 1000.0 * TAU * 1.3)
		cube_mat.set_shader_parameter("glint_size", 0.045 + 0.035 * tw)


## Centre of the cube on screen, in this control's local points.
func cube_center_local() -> Vector2:
	return Vector2(display_pts * 0.5, display_pts * 0.53)
