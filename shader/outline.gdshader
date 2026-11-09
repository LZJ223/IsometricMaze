shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

uniform sampler2D fill_texture : filter_linear, repeat_disable;
uniform sampler2D geometry_texture : filter_nearest, repeat_disable;
uniform vec2 pixel_size = vec2(0.001);
uniform vec4 ink_color : source_color = vec4(0.12, 0.18, 0.26, 1.0);
uniform float line_width : hint_range(0.0, 6.0) = 2.0;
uniform float depth_threshold : hint_range(0.005, 0.25) = 0.035;
uniform float depth_range = 100.0;
uniform float world_units_per_pixel = 0.01;
uniform vec3 camera_right = vec3(1.0, 0.0, 0.0);
uniform vec3 camera_up = vec3(0.0, 1.0, 0.0);
uniform vec3 camera_forward = vec3(0.0, 0.0, -1.0);

vec3 unpack_normal(float label) {
	int id = int(floor(label * 8.0 + 0.5));
	if (id == 1) { return vec3(1.0, 0.0, 0.0); }
	if (id == 2) { return vec3(-1.0, 0.0, 0.0); }
	if (id == 3) { return vec3(0.0, 1.0, 0.0); }
	if (id == 4) { return vec3(0.0, -1.0, 0.0); }
	if (id == 5) { return vec3(0.0, 0.0, 1.0); }
	return vec3(0.0, 0.0, -1.0);
}

float unpack_depth(vec4 data) {
	return (floor(data.g * 255.0 + 0.5) * 256.0 + floor(data.b * 255.0 + 0.5)) / 65535.0 * depth_range;
}

float edge_at(vec2 uv, vec2 delta) {
	vec4 a = texture(geometry_texture, uv);
	vec4 b = texture(geometry_texture, uv + delta * pixel_size);
	if (abs(a.a - b.a) > 0.5) { return 1.0; }
	if (a.a < 0.5) { return 0.0; }
	if (abs(a.r - b.r) > 0.06) { return 1.0; }
	// Remove the ordinary depth slope of the current plane. Only a real
	// disconnection between same-facing surfaces should produce a depth edge.
	vec3 n = unpack_normal(a.r);
	float denominator = dot(n, camera_forward);
	// Nearest data sampling snaps to pixel centers. Use the actual integer
	// sample separation rather than the fractional kernel radius.
	vec2 snapped_delta = floor(uv / pixel_size + delta) - floor(uv / pixel_size);
	vec3 planar_step = (camera_right * snapped_delta.x - camera_up * snapped_delta.y) * world_units_per_pixel;
	// Plane distance, without dividing by the grazing-angle denominator.
	float residual = dot(n, planar_step) + denominator * (unpack_depth(b) - unpack_depth(a));
	return step(depth_threshold, abs(residual));
}

float ink_at(vec2 uv) {
	float radius = line_width * 0.5;
	float edge = 0.0;
	for (int i = 0; i < 8; i++) {
		float angle = float(i) * 0.78539816339;
		edge = max(edge, edge_at(uv, vec2(cos(angle), sin(angle)) * radius));
	}
	return edge;
}

void fragment() {
	vec4 fill = texture(fill_texture, UV);
	float ink = 0.0;
	if (line_width > 0.0) {
		// Four subpixel samples anti-alias the post-process itself; MSAA on the
		// 3D fill alone cannot smooth a newly created screen-space stroke.
		ink += ink_at(UV + pixel_size * vec2(-0.25, -0.25));
		ink += ink_at(UV + pixel_size * vec2(0.25, -0.25));
		ink += ink_at(UV + pixel_size * vec2(-0.25, 0.25));
		ink += ink_at(UV + pixel_size * vec2(0.25, 0.25));
		ink *= 0.25 * ink_color.a;
	}
	// Both input and output use premultiplied coverage, including silhouette
	// expansion into previously transparent pixels.
	COLOR = vec4(mix(fill.rgb, ink_color.rgb, ink), ink + fill.a * (1.0 - ink));
}
