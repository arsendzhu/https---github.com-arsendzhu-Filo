// PS1-style post pass over the low-resolution mascot render:
// nearest-neighbour upscale happens via the TextureRect's filter; here we snap
// every pixel to the nearest colour of a small palette with a light ordered
// (Bayer 4x4) dither, and quantise alpha to hard 0/1 with the same pattern so
// the transparent window composites cleanly with no soft fringes.
shader_type canvas_item;

uniform int palette_size : hint_range(1, 16) = 9;
uniform vec3 palette[16];
uniform float dither : hint_range(0.0, 0.5) = 0.09;

const float BAYER[16] = float[16](
	0.0, 8.0, 2.0, 10.0,
	12.0, 4.0, 14.0, 6.0,
	3.0, 11.0, 1.0, 9.0,
	15.0, 7.0, 13.0, 5.0);

varying vec4 vcol;

void vertex() {
	vcol = COLOR;
}

void fragment() {
	vec4 src = texture(TEXTURE, UV);
	vec2 px = floor(UV / TEXTURE_PIXEL_SIZE);
	int bx = int(mod(px.x, 4.0));
	int by = int(mod(px.y, 4.0));
	float threshold = (BAYER[by * 4 + bx] + 0.5) / 16.0;
	float a = src.a >= threshold ? 1.0 : 0.0;
	vec3 c = src.rgb + (threshold - 0.5) * dither;
	vec3 best = c;
	float best_d = 1e9;
	for (int i = 0; i < 16; i++) {
		if (i >= palette_size) {
			break;
		}
		float d = distance(c, palette[i]);
		if (d < best_d) {
			best_d = d;
			best = palette[i];
		}
	}
	COLOR = vec4(best, a) * vcol;
}
