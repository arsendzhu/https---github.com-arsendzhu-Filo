// Soft contact shadow under the cube. Its alpha gradient becomes a dither
// pattern in the post pass, which grounds the bob animation in PS1 style.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;

uniform vec3 color : source_color = vec3(0.23, 0.19, 0.27);
uniform float strength : hint_range(0.0, 1.0) = 0.55;
uniform float softness : hint_range(0.0, 1.0) = 0.55;

void fragment() {
	vec2 d = (UV - 0.5) * 2.0;
	float r = length(d);
	float a = (1.0 - smoothstep(1.0 - softness, 1.0, r)) * strength;
	ALBEDO = color;
	ALPHA = a;
}
