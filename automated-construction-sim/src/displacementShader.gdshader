shader_type spatial;

uniform sampler2D noise;
uniform float height_scale = 1;
uniform sampler2D normalmap;

varying vec2 tex_position;

void vertex() {
	tex_position = UV;
  float height = texture(noise, tex_position).x;
  VERTEX.y += height * height_scale;
}

void fragment() {
	NORMAL_MAP = texture(normalmap, tex_position).xyz;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
