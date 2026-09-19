// Filo's body + face. Unshaded: we do a simple Lambert term ourselves so the
// palette post-pass can quantise and dither it. The face lives on the flat
// part of the +Z face in face-local units (1.0 = half the flat width) and is
// rasterised in the same low-res pass as the body, so it pixelates with it.
//
// Face vocabulary (cute = big round shiny eyes set wide and low, tiny mouth
// close to the eyes, soft blush):
//   eyes   two round-ish ovals with a shine dot in the upper-left; closed = short lines;
//          eye_style 1 = happy "^ ^" arches
//   mouth  mouth_style 0 = small smile line, 1 = "w" cat mouth; mouth_open > 0 = open oval
//   blush  soft cheek ovals below and outside the eyes
//   glint  the screen-reading cue: the shine dots turn cyan and twinkle
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

uniform vec3 body_color : source_color = vec3(0.945, 0.863, 0.737);
uniform vec3 ink_color : source_color = vec3(0.169, 0.141, 0.220);
uniform vec3 highlight_color : source_color = vec3(0.964, 0.911, 0.829);
uniform vec3 glint_color : source_color = vec3(0.70, 0.98, 0.95);
uniform vec3 blush_color : source_color = vec3(0.95, 0.60, 0.62);
uniform vec3 light_dir = vec3(-0.45, 0.80, 0.65);
uniform float ambient : hint_range(0.0, 1.0) = 0.42;
uniform float rim_darken : hint_range(0.0, 1.0) = 0.22;
uniform float face_extent = 0.36;
uniform vec2 eye_center = vec2(0.40, 0.08);
uniform vec2 eye_size = vec2(0.24, 0.20);
uniform float eye_open : hint_range(0.0, 1.3) = 1.0;
uniform vec2 eye_shift = vec2(0.0, 0.0);
uniform int eye_style = 0;
uniform float eye_highlight = 0.07;
uniform vec2 eye_asym = vec2(1.0, 1.0);   // per-eye openness multiplier (wink)
uniform int mouth_style = 0;
uniform float mouth_x = 0.0;
uniform float mouth_y = -0.26;
uniform float mouth_width = 0.11;
uniform float mouth_open : hint_range(0.0, 1.0) = 0.0;
uniform float mouth_curve = 0.12;
uniform float blush : hint_range(0.0, 1.0) = 0.0;
uniform float glint : hint_range(0.0, 1.0) = 0.0;
uniform float glint_size = 0.06;
uniform float jitter = 0.0;

varying vec3 obj_pos;
varying vec3 obj_normal;

void vertex() {
	obj_pos = VERTEX;
	obj_normal = NORMAL;
	vec4 clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	if (jitter > 0.0) {
		// PS1-style vertex snapping (off by default: cute wants chunky, not wobbly)
		float grid = 1.0 / jitter;
		vec2 ndc = clip.xy / clip.w;
		ndc = floor(ndc * grid + 0.5) / grid;
		clip.xy = ndc * clip.w;
	}
	POSITION = clip;
}

bool in_ellipse(vec2 p, vec2 c, vec2 r) {
	vec2 d = (p - c) / max(r, vec2(0.001));
	return dot(d, d) <= 1.0;
}

void fragment() {
	vec3 n = normalize(NORMAL);
	vec3 l = normalize((VIEW_MATRIX * vec4(normalize(light_dir), 0.0)).xyz);
	float diff = max(dot(n, l), 0.0);
	float lit = ambient + (1.0 - ambient) * diff;
	float rim = pow(1.0 - max(dot(n, vec3(0.0, 0.0, 1.0)), 0.0), 2.5);
	lit *= 1.0 - rim_darken * rim;
	vec3 col = body_color * lit;

	if (obj_normal.z > 0.85) {
		vec2 f = obj_pos.xy / face_extent;
		bool ink = false;
		bool shine = false;
		for (int i = 0; i < 2; i++) {
			float sx = (i == 0) ? -1.0 : 1.0;
			float eo = eye_open * ((i == 0) ? eye_asym.x : eye_asym.y);
			float eh = eye_size.y * max(eo, 0.0);
			vec2 c = vec2(sx * eye_center.x, eye_center.y) + eye_shift;
			if (eo < 0.12) {
				// closed: a short flat line
				if (in_ellipse(f, c, vec2(eye_size.x * 0.85, 0.05))) {
					ink = true;
				}
			} else if (eye_style == 1) {
				// happy arch "^"
				vec2 d = (f - c) / vec2(max(eye_size.x, 0.001), max(eye_size.y, 0.001));
				float r = length(d);
				if (d.y > -0.08 && abs(r - 0.75) < 0.28) {
					ink = true;
				}
			} else {
				if (in_ellipse(f, c, vec2(eye_size.x, eh))) {
					ink = true;
					float hs = (glint > 0.5) ? glint_size : eye_highlight;
					if (hs > 0.0 && eo > 0.35) {
						vec2 h = c + vec2(-eye_size.x * 0.34, eh * 0.30);
						if (in_ellipse(f, h, vec2(hs, hs))) {
							shine = true;
						}
					}
				}
			}
			if (blush > 0.01) {
				vec2 b = vec2(sx * (eye_center.x + 0.20), eye_center.y - 0.30);
				if (in_ellipse(f, b, vec2(0.12, 0.06) * (0.6 + 0.4 * blush))) {
					col = mix(col, blush_color, 0.55 + 0.45 * blush);
				}
			}
		}
		vec2 mf = f - vec2(mouth_x, 0.0);
		if (mouth_open > 0.05) {
			float mh = mix(0.05, 0.16, mouth_open);
			if (in_ellipse(mf, vec2(0.0, mouth_y), vec2(mouth_width, mh))) {
				ink = true;
			}
		} else if (mouth_style == 1) {
			float hw = mouth_width * 0.55;
			for (int k = 0; k < 2; k++) {
				float cx = ((k == 0) ? -1.0 : 1.0) * mouth_width * 0.5;
				float cy = mouth_y + mouth_curve * pow((mf.x - cx) / max(hw, 0.01), 2.0);
				if (in_ellipse(mf, vec2(cx, cy), vec2(hw, 0.05))) {
					ink = true;
				}
			}
		} else {
			float cy = mouth_y + mouth_curve * pow(mf.x / max(mouth_width, 0.01), 2.0);
			if (in_ellipse(mf, vec2(0.0, cy), vec2(mouth_width, 0.05))) {
				ink = true;
			}
		}
		if (ink) {
			col = ink_color;
		}
		if (shine) {
			col = (glint > 0.5) ? glint_color : highlight_color;
		}
	}
	ALBEDO = col;
}
