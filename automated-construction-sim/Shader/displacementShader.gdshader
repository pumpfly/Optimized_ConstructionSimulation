shader_type spatial;

uniform sampler2D heightmap: filter_nearest, repeat_disable;
uniform float height_scale = 1;
uniform float color_min = 0.0;  // Minimum height value in your heightmap
uniform float color_max = 1.0;  // Maximum height value in your heightmap
//uniform sampler2D normalmap;

varying vec2 tex_position;

void vertex() {
	tex_position = UV;
	float height = texture(heightmap, tex_position).r;
	VERTEX.y += height * height_scale;
}

void fragment() {
	// Sample heightmap
	float height = texture(heightmap, UV).r;

	// Remap height from [color_min, color_max] to [0.0, 1.0] for better visualization
	float height_normalized = (height - color_min) / (color_max - color_min);
	height_normalized = clamp(height_normalized, 0.0, 1.0);

	// Color gradient: valleys (green) -> mid (brown) -> peaks (white)
	vec3 low_color = vec3(0.2, 0.5, 0.2);    // Green valleys
	vec3 mid_color = vec3(0.6, 0.4, 0.2);    // Brown mid-elevation
	vec3 high_color = vec3(0.9, 0.9, 0.9);   // White peaks

	// Two-stage gradient for more natural terrain coloring
	vec3 color = mix(low_color, mid_color, smoothstep(0.21, 0.23, height_normalized));
	color = mix(color, high_color, smoothstep(0.25, 0.29, height_normalized));

	ALBEDO = color;
}
