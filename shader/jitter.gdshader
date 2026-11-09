shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

uniform vec2 image_size = vec2(1280.0, 800.0);
uniform vec2 world_origin_pixel = vec2(0.0);
uniform vec3 view_direction = vec3(1.0);
uniform float style_seed = 17.0;
uniform float jitter_amplitude : hint_range(0.0, 3.0) = 0.85;
uniform float jitter_wavelength : hint_range(24.0, 120.0) = 48.0;

float hash_point(vec2 p, float channel) {
	return fract(sin(dot(p, vec2(127.1, 311.7)) + style_seed * 17.17 + channel * 53.3) * 43758.5453);
}

float noise(vec2 p, float channel) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash_point(cell, channel), hash_point(cell + vec2(1, 0), channel), f.x),
		mix(hash_point(cell + vec2(0, 1), channel), hash_point(cell + vec2(1, 1), channel), f.x), f.y);
}

void fragment() {
	// Continuous direction coordinates rather than hashing camera angles.
	// No TIME, frame counter, mutable RNG, or geometry-dependent seed.
	vec2 angle_offset = vec2(view_direction.x + view_direction.z * 0.37, view_direction.y + view_direction.z * 0.61) * 2.5;
	vec2 p = (UV * image_size - world_origin_pixel) / jitter_wavelength + angle_offset;
	vec2 displacement = vec2(noise(p, 0.0), noise(p, 1.0)) * 2.0 - 1.0;
	displacement += (vec2(noise(p * 2.1, 2.0), noise(p * 2.1, 3.0)) * 2.0 - 1.0) * 0.15;
	vec2 source_uv = UV + displacement * jitter_amplitude / image_size;
	// Fill, ink, and coverage are already one image and follow this exact
	// same inverse warp. Sampling never exposes an unfilled old silhouette.
	COLOR = texture(TEXTURE, source_uv);
}
