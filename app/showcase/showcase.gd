class_name Showcase
extends Node
## `--showcase`: tours every mascot state with sample bubble content so the
## animation designs can be reviewed (and captured with --capture-dir DIR).

const SAMPLE_QUESTION := "I'm stuck on the Guardian Ape, what am I missing?"
const SAMPLE_ANSWER := "Firecrackers are the trick: the ape is an animal, so the Shinobi Firecracker staggers it and opens it up for free hits. In the headless phase, run away from its scream to avoid Terror and keep attacking from behind."
const SAMPLE_SOURCES := [{"kind": "kb", "title": "Guardian Ape", "url": "https://sekiro-shadows-die-twice.fandom.com/wiki/Guardian_Ape"}]

var main: Node
var capture_dir := ""
var frame_index := 0


func run(main_node: Node, dir: String) -> void:
	main = main_node
	capture_dir = dir
	if capture_dir != "":
		DirAccess.make_dir_recursive_absolute(capture_dir)
	FiloLog.info("Showcase: starting" + ("" if capture_dir == "" else " (captures -> " + capture_dir + ")"))
	main._set_fps(true)
	var an: MascotAnimator = main.mascot.animator
	var bubble: Bubble = main.bubble
	await _wait(0.5)
	await _capture("00_asleep")

	an.wake()
	await _capture_series("wake", MascotAnimator.WAKE_DURATION, 6)
	main._show_hint()
	await _wait(0.3)
	bubble.show_info("Hi, I'm Filo. Hold %s to ask me something — tap it to type instead." % main.cfg.hotkey_label())
	await _wait(1.0)
	await _capture("idle")
	an.trigger_blink()
	await _wait(0.08)
	await _capture("idle_blink")
	await _wait(1.2)

	an.set_state(MascotAnimator.State.LISTENING)
	bubble.show_listening("")
	await _wait(0.8)
	bubble.show_listening("I'm stuck on the Guardian Ape")
	for i in 8:
		an.set_level(0.35 + 0.5 * float(i % 3) / 2.0)
		await _wait(0.12)
	await _capture("listening")
	await _wait(0.8)

	an.set_state(MascotAnimator.State.THINKING)
	bubble.show_thinking(SAMPLE_QUESTION)
	await _wait(1.3)
	await _capture("thinking")
	await _wait(1.4)

	an.set_state(MascotAnimator.State.ANSWERING)
	bubble.show_answer(SAMPLE_QUESTION, SAMPLE_ANSWER, SAMPLE_SOURCES, false)
	var words := SAMPLE_ANSWER.split(" ")
	var pos := 0
	for i in words.size():
		an.talk_pulse()
		bubble.reveal_to(pos)
		pos += words[i].length() + 1
		if i == 12:
			await _capture("answering")
		await _wait(0.14)
	bubble.reveal_all()
	await _wait(0.6)

	an.set_state(MascotAnimator.State.IDLE)
	await _wait(0.5)
	await _capture("pleased")
	await _wait(1.2)
	an.react_after_answer("wink")
	await _wait(0.5)
	await _capture("wink")
	await _wait(1.2)
	an.react_after_answer("hop")
	await _wait(0.12)
	await _capture("hop")
	await _wait(1.5)
	an.set_glint(true)
	bubble.show_info("Screen-reading cue preview: the glint stays in my eyes only while screen access is on (off by default; not part of Phase 0).")
	await _wait(0.8)
	await _capture("glint_screen_reading_cue")
	await _wait(0.9)
	an.set_glint(false)

	bubble.show_error("Example error: Claude rejected the API key. Check anthropic_api_key in config.json.")
	an.play_error()
	await _wait(0.2)
	await _capture("error")
	await an.error_finished
	await _wait(0.6)

	bubble.hide_bubble()
	an.sleep()
	await _capture_series("sleep", MascotAnimator.SLEEP_DURATION, 6)
	await _wait(0.5)
	await _capture("99_asleep_again")
	FiloLog.info("Showcase: done")
	main.showcase_done()


func _wait(seconds: float) -> void:
	await main.get_tree().create_timer(seconds).timeout


func _capture_series(label: String, duration: float, count: int) -> void:
	var step := duration / float(count)
	for i in count:
		await _capture("%s_%d" % [label, i])
		await _wait(step)


func _capture(label: String) -> void:
	if capture_dir == "":
		return
	if not label.contains("blink"):
		main.mascot.animator.hold_blink(1.0)
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	var stem := "%02d_%s" % [frame_index, label]
	frame_index += 1
	img.save_png(capture_dir.path_join(stem + ".png"))
	# review copy: composite over a dark checkerboard so transparency is visible
	var bg := Image.create_empty(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
	var cell := 32
	for y in range(0, img.get_height(), cell):
		for x in range(0, img.get_width(), cell):
			var dark := ((x / cell) + (y / cell)) % 2 == 0
			bg.fill_rect(Rect2i(x, y, cell, cell), Color(0.20, 0.21, 0.24) if dark else Color(0.27, 0.28, 0.31))
	img.convert(Image.FORMAT_RGBA8)
	bg.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i.ZERO)
	bg.save_png(capture_dir.path_join(stem + "_review.png"))
	FiloLog.info("Captured " + stem)
