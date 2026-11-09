extends Node
## Object-only rendering. Three isolated viewports, shared source Mesh, and a
## transparent canvas presentation keep post-processing away from game UI.

const OUTLINE_SHADER = preload("res://shader/outline.gdshader")
const JITTER_SHADER = preload("res://shader/jitter.gdshader")
const DATA_SHADER = preload("res://shader/geometry_data.gdshader")

@export_category("屏幕空间描边")
@export_range(0.0, 6.0, 0.1) var line_width: float = 2.0
@export var ink_color := Color("203047")
@export_range(0.005, 0.25, 0.005) var depth_threshold: float = 0.035
@export_category("静态手绘抖动")
@export_range(0.0, 3.0, 0.05) var jitter_amplitude: float = 0.85
@export_range(24.0, 120.0, 1.0) var jitter_wavelength: float = 48.0
@export var style_seed: int = 17

var color_viewport: SubViewport
var data_viewport: SubViewport
var outline_viewport: SubViewport
var color_mesh: MeshInstance3D
var data_mesh: MeshInstance3D
var color_camera: Camera3D
var data_camera: Camera3D
var outline_material := ShaderMaterial.new()
var jitter_material := ShaderMaterial.new()
var data_material := ShaderMaterial.new()
var _presentation: CanvasLayer
var _output: TextureRect
var _outline_rect: ColorRect
var _source: MeshInstance3D
var _camera: Camera3D
var _geometry_visible := true
var _size := Vector2i.ZERO


func setup(source: MeshInstance3D, camera: Camera3D, environment: Environment, light: DirectionalLight3D) -> void:
	_source = source
	_camera = camera
	# Keep the public source nodes in the main world for projection/picking;
	# actual geometry is rendered exactly once into the color viewport.
	_source.layers = 0
	color_viewport = _make_viewport("FillViewport", true)
	data_viewport = _make_viewport("GeometryDataViewport", true)
	outline_viewport = _make_viewport("OutlineViewport", false)
	color_viewport.msaa_3d = Viewport.MSAA_4X
	var color_world := Node3D.new()
	color_viewport.add_child(color_world)
	color_mesh = MeshInstance3D.new()
	color_mesh.material_override = source.material_override
	color_world.add_child(color_mesh)
	color_camera = Camera3D.new()
	color_world.add_child(color_camera)
	var fill_environment := WorldEnvironment.new()
	fill_environment.environment = environment.duplicate()
	fill_environment.environment.background_mode = Environment.BG_CLEAR_COLOR
	color_world.add_child(fill_environment)
	var fill_light: DirectionalLight3D = light.duplicate()
	color_camera.add_child(fill_light)
	var data_world := Node3D.new()
	data_viewport.add_child(data_world)
	data_material.shader = DATA_SHADER
	data_mesh = MeshInstance3D.new()
	data_mesh.material_override = data_material
	data_world.add_child(data_mesh)
	data_camera = Camera3D.new()
	data_world.add_child(data_camera)
	var data_environment := WorldEnvironment.new()
	data_environment.environment = Environment.new()
	data_environment.environment.background_mode = Environment.BG_CLEAR_COLOR
	data_environment.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	data_world.add_child(data_environment)
	outline_material.shader = OUTLINE_SHADER
	outline_material.set_shader_parameter("fill_texture", color_viewport.get_texture())
	outline_material.set_shader_parameter("geometry_texture", data_viewport.get_texture())
	_outline_rect = ColorRect.new()
	_outline_rect.material = outline_material
	_outline_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outline_viewport.add_child(_outline_rect)
	_presentation = CanvasLayer.new()
	_presentation.layer = 1
	add_child(_presentation)
	jitter_material.shader = JITTER_SHADER
	_output = TextureRect.new()
	_output.texture = outline_viewport.get_texture()
	_output.material = jitter_material
	_output.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_output.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_output.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_presentation.add_child(_output)
	sync_frame()


func _make_viewport(label: String, three_dimensional: bool) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = label
	viewport.transparent_bg = true
	viewport.disable_3d = not three_dimensional
	viewport.own_world_3d = three_dimensional
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	return viewport


func set_geometry_visible(value: bool) -> void:
	_geometry_visible = value
	if _presentation != null:
		_presentation.visible = value
		for viewport: SubViewport in [color_viewport, data_viewport, outline_viewport]:
			viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if value else SubViewport.UPDATE_DISABLED


func _process(_delta: float) -> void:
	sync_frame()


func sync_frame() -> void:
	if _source == null or _camera == null:
		return
	var logical_size := Vector2i(get_viewport().get_visible_rect().size)
	if logical_size != _size:
		_size = logical_size.max(Vector2i.ONE)
		for viewport: SubViewport in [color_viewport, data_viewport, outline_viewport]:
			viewport.size = _size
		_outline_rect.size = Vector2(_size)
		_output.size = Vector2(_size)
	# Whole-view transparent padding preserves the existing camera mapping and
	# allows strokes/jitter to extend beyond the original object's rectangle.
	for target: MeshInstance3D in [color_mesh, data_mesh]:
		target.mesh = _source.mesh
		target.global_transform = _source.global_transform
	for target: Camera3D in [color_camera, data_camera]:
		target.projection = _camera.projection
		target.keep_aspect = _camera.keep_aspect
		target.size = _camera.size
		target.near = _camera.near
		target.far = _camera.far
		target.global_transform = _camera.global_transform
	data_material.set_shader_parameter("depth_range", _camera.far)
	outline_material.set_shader_parameter("depth_range", _camera.far)
	outline_material.set_shader_parameter("pixel_size", Vector2.ONE / Vector2(_size))
	outline_material.set_shader_parameter("line_width", line_width)
	outline_material.set_shader_parameter("ink_color", ink_color)
	outline_material.set_shader_parameter("depth_threshold", depth_threshold)
	outline_material.set_shader_parameter("world_units_per_pixel", _camera.size / float(_size.y))
	outline_material.set_shader_parameter("camera_right", _camera.global_basis.x)
	outline_material.set_shader_parameter("camera_up", _camera.global_basis.y)
	outline_material.set_shader_parameter("camera_forward", -_camera.global_basis.z)
	jitter_material.set_shader_parameter("image_size", Vector2(_size))
	jitter_material.set_shader_parameter("world_origin_pixel", _camera.unproject_position(Vector3.ZERO))
	jitter_material.set_shader_parameter("view_direction", _camera.global_basis.z)
	jitter_material.set_shader_parameter("style_seed", float(style_seed))
	var amplitude := clampf(jitter_amplitude, 0.0, 3.0)
	jitter_material.set_shader_parameter("jitter_amplitude", amplitude)
	# Bound the displacement gradient as well as its amplitude. A short,
	# large-amplitude warp would visibly stretch the precomposed ink width.
	jitter_material.set_shader_parameter("jitter_wavelength", maxf(jitter_wavelength, maxf(24.0, amplitude * 16.0)))
