# Mascot animation & face design (Phase 0)

Everything the cube does is in [`app/mascot/mascot_animator.gd`](../app/mascot/mascot_animator.gd),
the face sprites in [`app/mascot/face_sprites.gd`](../app/mascot/face_sprites.gd), and the look
itself in the three shaders under [`app/mascot/shaders/`](../app/mascot/shaders/). Run
`scripts/run.sh --showcase` to tour every state (add `--capture-dir DIR` to save frames).

## The rig

There is no skeleton. A `Pivot` node carries the procedural rounded cube; the animator writes
`position`, `rotation_degrees` and `scale` on it every frame as

```
final = base (tweened per state / choreography) + procedural layer (bob, sway, pulse, spin) * proc_blend
```

`proc_blend` eases between 0 and 1 (rate 6/s) so procedural motion never pops in or out. The
face is a set of shader parameters; each state selects a **sprite pair** (eyes + mouth) that the
animator eases toward at 14/s, so expressions cross-fade rather than snap.

## The look (PS1 pipeline)

| stage | where | what |
| --- | --- | --- |
| geometry | `rounded_box_mesh.gd` | 1.0 cube, corner radius 0.18, 12 subdivisions per face, vertices projected onto the rounded-box surface (clamp to inner box, offset by radius) with exact normals; samples biased toward edges |
| low-res render | `mascot.gd` | 96×96 SubViewport, transparent background, no MSAA, perspective camera (fov 30°) slightly above the cube |
| shading | `cube_face.gdshader` | unshaded: own Lambert term (key light upper-left-front, ambient 0.42) plus a rim darkening (0.22) that makes the silhouette read "soft" |
| upscale | `mascot.gd` | TextureRect with nearest filtering, sized so every internal pixel is a whole number of physical pixels (4× on a 2× display at the default 200 pt → 192 pt on screen) |
| palette + dither | `psx_post.gdshader` | nearest colour out of 9 palette entries (5-step cream ramp, ink, glint, blush, shadow) after adding a Bayer 4×4 offset of ±0.045; alpha is dithered to hard 0/1 so the transparent window never shows soft fringes |
| vertex jitter | `cube_face.gdshader` | available (`mascot.vertex_jitter`), **off by default** — cute wants chunky, not wobbly |

## The face

The face follows the well-documented rules of "cute" (baby-schema proportions): big round eyes
placed at mid-face and set wide apart, a tiny mouth just below the eyes, soft rounded shapes,
a small pastel palette, and shiny eyes (a highlight dot gives the eye life). Shapes and
proportions are our own; nothing is traced from an existing mascot.

Drawn on the flat part of the +Z face in face-local units (1.0 = half the flat width) through the
same low-res pass, so it pixelates with the body. Each eye is an oval (0.24 × 0.20 ≈ 10 × 9 px)
with a cream shine dot in its upper-left; the mouth is a short curved line whose corners lift
(`mouth_curve`), a "w" cat mouth, or an open oval while talking.

| sprite | eyes | mouth | blush |
| --- | --- | --- | --- |
| idle | round, shine dot, centred at (±0.40, 0.08) | tiny smile (half-width 0.11, curve 0.12) at y −0.26 | 0.3 (always a little rosy) |
| listening | bigger (0.26 × 0.23), lifted 0.02 | small "o" (open 0.45) | 0.7 |
| thinking | half closed (0.55), glancing up-right (+0.06, +0.10) | short flat line shifted right ("hmm") | 0.15 |
| answering | idle eyes | open 0.15 base + a flap per spoken word | 0.5 |
| pleased ("happy") | happy "^ ^" arches | "w" cat mouth | 0.7 — after-answer reaction and an idle mood |
| wink | right eye closed (`eye_asym`), head tilts 7° | wide smile, slightly off-centre | 0.55 — after-answer reaction |
| curious | wider, glancing up-and-over (+0.09, +0.05) | small "o", slight smile | 0.35 — idle mood |
| focused ("locked in") | narrowed (0.72), looking straight ahead | narrow, level, a touch determined | 0.15 — idle mood |
| cute | noticeably bigger (0.27 × 0.23), extra shine | wide warm smile (curve 0.16) | 0.65 — idle mood |
| thinking (hmm) | 0.7 open, glancing up-left | short line pushed left | 0.15 — the head-tilt thinking variant |
| asleep | closed → short flat lines | tiny smile | 0.2 |
| error | 0.45 open, lowered | frown (−0.14) | 0.1 |

Every sprite above resolves through one shared template (`FaceSprites.BASE`, merged with each
sprite's own overrides) so every field — including `eye_asym`, the per-eye openness wink uses —
is always present on every sprite. This is deliberate: the per-frame face lerp only ever eases a
field *toward* whatever the current target sprite specifies, so a field a sprite leaves out never
gets a value to ease back to. That gap used to be real (`eye_asym` lived only on "wink"), and its
symptom was exactly a mascot that would end up speaking with one eye stuck shut, later in a
session, once a wink happened to fire — fixed by guaranteeing the full field set everywhere,
never by special-casing "wink" itself.

Blinks: every 2.4–5.2 s in idle/listening/answering (20 % double), 0.16 s each.

**Idle mood rotation.** So the resting face doesn't read as fixed over a long session, `IDLE`
rests on one of `idle · curious · focused · cute · pleased` at a time — never on listening,
thinking or answering, which keep their own single, clear expression so the state is always
unambiguous. `MascotAnimator.register_turn()` (called once per completed answer) advances to a
different mood roughly every 1–2 questions; `idle`, the original look, stays in the rotation
rather than being replaced, so it keeps coming back. A fresh "hey filo" always resets to plain
`idle` first, so the well-liked wake-up look is never disturbed — variety only builds up as the
conversation goes on, and it never gets permanently stuck on any one of them.

**Screen-reading cue.** `set_glint(true)` turns the shine dots cyan and makes them twinkle
between 1 px and 2 px (1.3 Hz) — the always-visible sign that screen access is on. Phase 0
ships it off and only previews it (`/glint` in the typed panel, or the showcase).

## Choreography

### Summon (`wake()`, 0.8 s)
One `tween_method` drives progress *p* 0→1; each channel has its own curve:

| channel | curve | effect |
| --- | --- | --- |
| scale | ease-out-back, overshoot 1.55 | grows from nothing, peaks ≈ 1.06 then settles: the landing bounce |
| rotation Y | 360° × (1 − ease-out-back 0.8) | one full spin, readable through the first half, tiny wobble past 0° |
| alpha | ease-out-sine over the first 60 % | fades in while small |
| eyes | closed until p = 0.78, then ease-out-back 1.7 over 0.16 | eyes pop open right at the end of the spin |

Ends in **idle** and emits `wake_finished`.

### Dismiss (`sleep()`, 0.62 s)
The same system with the sign and curve flipped:

| channel | curve | effect |
| --- | --- | --- |
| scale | 1 − ease-in-sine | shrinks gently, no overshoot |
| rotation Y | −360° × ease-in-sine, on top of the current pose easing to zero | spins the opposite way |
| alpha | 1 → 0 over the last 60 % | fades out as it shrinks |
| eyes | close between p = 0.22 and 0.42 | eyes shut part-way through |

Ends in **hidden** and emits `sleep_finished`.

## States

| state | base transform (tweened on entry) | procedural layer |
| --- | --- | --- |
| idle | back to origin (0.35 s cubic-out) | bob y ±0.06 (2.4 s), sway z ±2° (5.3 s), yaw ±4° (7.1 s), blinks, **fidgets** |
| listening / waiting for a follow-up | levitates: y +0.12, z +0.06 (0.45 s sine-out) | slow float ±0.05 (3.2 s), yaw ±3° (6.5 s), scale pulse ±2 % at 0.9 s **plus** mic level × 7 %, lean x −6°, an ear-tilt fidget every 3.5–7 s |
| thinking | y +0.05 | 60 %: continuous spin 70°/s about Y with tilt z +8°; 40 %: "hmm" — tilt z +10°, slow nod x ±3° (1.8 s), eyes up-left, mouth pushed to the side; leaving the state settles the spin the short way round |
| answering | yaw −11° toward the bubble (the "directional point"); nudge z 0 → 0.32 (0.16 s back-out) → 0.12 (0.3 s sine-out) held while speaking | bob ±0.035 and roll ±1.5° at 1.3 s; mouth follows the voice: a flap per word (system voice) or the audio envelope (Kokoro) |
| got it | | a quick nod (x ±9°, 0.42 s) the moment a question is understood |
| after an answer | one random reaction for 1.5 s while "anything else?" is spoken: **pleased** (^ ^ + w mouth), **wink** (+7° tilt), **hop** (y +0.28 quad-out, bounce down), **nod** | |
| farewell | "bye filo": happy face, a hop and a side-to-side wiggle (z +8° / −8°) while it says bye, then the dismiss spin | |
| error | `play_error()`: head shake z 7, −7, 5, −4, 2, 0 (0.065 s each), unhappy sprite, 0.75 s hold, then back to idle | |

### Fidgets (secondary idles)

Following the usual game-animation practice of a base loop plus randomized secondary idles,
every 4–9 s in idle one of these plays: a **glance** to one side (eye shift ±0.09 for 1.4 s), a
**stretch** (scale y +7 %, x −4 %, 0.5 s), a **head tilt** (±6° over 1.3 s) or a **double blink**.
While listening the fidget is an **ear tilt** (z ±9°, y ±4°). Fidgets pause during reactions.

The **contact shadow** (dithered ellipse under the cube) shrinks and fades as the cube rises,
which is what makes the bob read as a hop rather than a slide.

## Timings the UI adds on top

| moment | detail |
| --- | --- |
| bubble appear | scale 0.9 → 1 (0.22 s back-out) + fade 0.16 s, pivot on the tail side; 2 pt cream border, 10 pt radius |
| answer text | revealed word by word from the TTS boundary callbacks (simulated timing when muted) |
| hint under the cube | "say “hey filo” · hold ⌥ Space · say “bye filo” or tap ⌥ Space to dismiss" fades in on wake, out after 5 s |
| after an answer | reaction + spoken "anything else?" (varied), then the bubble shows "● Listening" with "say “bye filo” when you're done" |
| dismiss | only on "bye filo" or a tap of the key (spoken farewell, then the dismiss spin); the launch greeting still sleeps after 8 s |
