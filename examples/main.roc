app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	base64: "../package/main.roc",
}

import pf.Stdout
import base64.Base64

main! = |_| {
	# URL-safe alphabet, unpadded, for URLs, JWTs, file names etc.
	lyrics = "I'd like to live on the moon, or maybe live in on a star... Or will I be like you, dad, and live in the car?"
	url_safe = Base64.encode_url(lyrics.to_utf8())
	Stdout.line!("URL-safe: ${url_safe}")?

	# Standard alphabet, padded, for MIME, data URIs, etc.
	encoded = Base64.encode("https://www.youtube.com/watch?v=QG_TBIGY2Iw".to_utf8())
	Stdout.line!("Encoded: ${encoded}")?

	Stdout.line!("Decoded: ${decode_to_str(encoded)}")?

	Ok({})
}

decode_to_str : Str -> Str
decode_to_str = |encoded|
	match Base64.decode(encoded) {
		Ok(bytes) => Str.from_utf8(bytes) ?? "Invalid UTF-8"
		Err(e) => "Decode failed: ${Str.inspect(e)}"
	}
