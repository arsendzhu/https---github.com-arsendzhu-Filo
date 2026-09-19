class_name FiloArgs
extends RefCounted
## Parses the user arguments passed after "--" on the command line.
##
## Flags:  --showcase  --mute  --no-helper  --no-greet  --verbose
## Values: --ask "question"  --capture-dir DIR  --quit-after SECONDS  --profile ID
##         --helper-cmd PATH  --helper-args "a b c"  --api-base URL  --config PATH  --port N
## Keys are returned with dashes converted to underscores (e.g. "capture_dir").

const VALUE_FLAGS := ["ask", "capture-dir", "quit-after", "profile", "helper-cmd", "helper-args", "api-base", "config", "port", "provider", "nim-base", "wiki-base", "tts-provider"]


## Splits a command line the way a shell would: spaces separate arguments,
## single or double quotes group words, backslash escapes the next character.
static func split_shell(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var current := ""
	var quote := ""
	var has_token := false
	var i := 0
	while i < text.length():
		var ch := text[i]
		if quote != "":
			if ch == quote:
				quote = ""
			else:
				current += ch
		elif ch == "\"" or ch == "'":
			quote = ch
			has_token = true
		elif ch == "\\" and i + 1 < text.length():
			i += 1
			current += text[i]
			has_token = true
		elif ch == " " or ch == "\t":
			if has_token:
				out.append(current)
				current = ""
				has_token = false
		else:
			current += ch
			has_token = true
		i += 1
	if has_token:
		out.append(current)
	return out


static func parse(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		var a := argv[i]
		if a.begins_with("--"):
			var key := a.substr(2)
			var value = true
			if key.contains("="):
				var parts := key.split("=", true, 1)
				key = parts[0]
				value = parts[1]
			elif key in VALUE_FLAGS and i + 1 < argv.size():
				i += 1
				value = argv[i]
			out[key.replace("-", "_")] = value
		i += 1
	return out
