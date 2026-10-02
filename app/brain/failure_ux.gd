class_name FailureUX
extends RefCounted
## Every failure gets a short spoken sentence and a visual message that says what to do - never silence and
## never a raw error code. classify() takes whatever the app has (an error string from an API client, or the
## helper's error code) and returns {kind, spoken, visual}.

const KINDS := {
	"no_microphone": {
		"spoken": "I can't find a microphone. Tap the key to type instead.",
		"visual": "I can't find a microphone. Check your input device in System Settings, or tap the hotkey to type your question.",
	},
	"mic_permission": {
		"spoken": "I don't have permission to use the microphone.",
		"visual": "Microphone or speech access is off for Filo Helper. Allow it in System Settings, Privacy & Security, then restart me. Tapping the hotkey still lets you type.",
	},
	"speech_unavailable": {
		"spoken": "Speech recognition isn't available right now. Tap the key to type.",
		"visual": "Speech recognition isn't available on this Mac right now. Tap the hotkey to type your question instead.",
	},
	"recognition": {
		"spoken": "I couldn't make out what you said. Try again.",
		"visual": "Speech recognition failed for that question. Try again, or tap the hotkey to type it.",
	},
	"no_internet": {
		"spoken": "I can't reach the internet right now.",
		"visual": "I can't reach the internet, so I can only answer from my notes. Check your connection and ask again.",
	},
	"service_down": {
		"spoken": "The AI service is having trouble right now. Try again in a moment.",
		"visual": "The AI service is having trouble or is too slow right now. Try again in a moment; I'll use my notes and Wikipedia when I can.",
	},
	"rate_limited": {
		"spoken": "I'm being rate limited. Give me a few seconds.",
		"visual": "The AI service is rate limiting me (the free tier allows about 40 requests a minute). Wait a few seconds and ask again.",
	},
	"bad_key": {
		"spoken": "My API key was rejected.",
		"visual": "The API key was rejected. Check NVIDIA_API_KEY (or ANTHROPIC_API_KEY) in .env.",
	},
	"no_key": {
		"spoken": "I don't have an API key, so I can only read from my notes.",
		"visual": "No API key is set, so I can only answer from my notes. Add NVIDIA_API_KEY to .env to unlock the rest.",
	},
	"not_found": {
		"spoken": "I couldn't find that in the wiki.",
		"visual": "I couldn't find that in the wiki. Try different words, or ask about a specific boss, item or place.",
	},
	"helper_unconfirmed": {
		"spoken": "The microphone mute isn't confirmed. My helper may be out of date.",
		"visual": "The hotkey helper did not confirm the microphone change, so it may be an old build and the microphone might still be on. Run scripts/build_helper.sh and restart Filo.",
	},
	"muted": {
		"spoken": "The microphone is muted.",
		"visual": "The microphone is muted. Click the mic button or press the mute hotkey to unmute, or tap the hotkey to type.",
	},
	"generic": {
		"spoken": "Something went wrong. Try again.",
		"visual": "Something went wrong. Try again in a moment.",
	},
}


static func classify(raw: String, code: String = "") -> Dictionary:
	var kind := _kind_of(raw.to_lower(), code.to_lower())
	var k: Dictionary = KINDS[kind]
	return {"kind": kind, "spoken": k.spoken, "visual": k.visual}


static func _kind_of(msg: String, code: String) -> String:
	match code:
		"no_input_device", "audio_engine":
			return "no_microphone"
		"mic_denied", "speech_denied":
			return "mic_permission"
		"speech_unavailable":
			return "speech_unavailable"
		"recognition":
			return "recognition"
		"muted":
			return "muted"
		"helper_unconfirmed":
			return "helper_unconfirmed"
	if msg.contains("internet") or msg.contains("can't reach") or msg.contains("could not connect") or msg.contains("network error") or msg.contains("no internet"):
		return "no_internet"
	if msg.contains("rate-limit") or msg.contains("rate limit") or msg.contains("429") or msg.contains("overloaded") or msg.contains("budget"):
		return "rate_limited"
	if msg.contains("api key") and (msg.contains("rejected") or msg.contains("isn't allowed") or msg.contains("invalid")):
		return "bad_key"
	if msg.contains("no api key") or msg.contains("no nvidia api key") or msg.contains("no usable api key"):
		return "no_key"
	if msg.contains("having trouble") or msg.contains("took too long") or msg.contains("timed out") or msg.contains("timeout") or msg.contains("error 5") or msg.contains("unavailable") or msg.contains("bad gateway") or msg.contains("end of life") or msg.contains("http 5") or msg.contains("gone"):
		return "service_down"
	if msg.contains("no wiki") or msg.contains("couldn't find") or msg.contains("could not find") or msg.contains("not found") or msg.contains("no results"):
		return "not_found"
	return "generic"
