shader_type spatial;

uniform sampler2D heightmap: filter_nearest, repeat_disable;
uniform float height_scale = 1;

varying vec2 tex_position;

void vertex() {
	tex_position = UV;
	float height = texture(heightmap, tex_position).r;
	VERTEX.y += height * height_scale;
}

void fragment(){
	ALBEDO = texture(heightmap, UV).rgb;
}
