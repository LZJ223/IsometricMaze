shader_type spatial;
render_mode unshaded, fog_disabled;

// RGBA8 data: six-axis world normal label, packed 16-bit linear view depth,
// opaque coverage. The data viewport uses linear tonemapping and no MSAA.
uniform float depth_range = 100.0;
varying vec3 world_normal;
varying float view_depth;

vec3 encode_framebuffer_data(vec3 bytes) {
	// Compatibility converts ALBEDO with its cubic sRGB approximation and
	// converts back using a power curve. That round trip is NOT byte-exact,
	// even with linear tonemapping. Invert that cubic here so packed depth
	// survives the ordinary RGBA8 framebuffer. This is data, not artwork.
	vec3 linear_target = pow((bytes + vec3(0.055)) / 1.055, vec3(2.4));
	vec3 low = vec3(0.0);
	vec3 high = vec3(1.0);
	for (int i = 0; i < 14; i++) {
		vec3 middle = (low + high) * 0.5;
		vec3 decoded = middle * (middle * (middle * 0.305306011 + 0.682171111) + 0.012522878);
		vec3 below = step(decoded, linear_target);
		low = mix(low, middle, below);
		high = mix(middle, high, below);
	}
	return (low + high) * 0.5;
}

void vertex() {
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	view_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}

void fragment() {
	vec3 n = normalize(world_normal);
	float label;
	if (abs(n.x) > 0.5) {
		label = n.x > 0.0 ? 1.0 : 2.0;
	} else if (abs(n.y) > 0.5) {
		label = n.y > 0.0 ? 3.0 : 4.0;
	} else {
		label = n.z > 0.0 ? 5.0 : 6.0;
	}
	float packed = floor(clamp(view_depth / depth_range, 0.0, 1.0) * 65535.0 + 0.5);
	ALBEDO = encode_framebuffer_data(vec3(label / 8.0, floor(packed / 256.0) / 255.0, mod(packed, 256.0) / 255.0));
}
