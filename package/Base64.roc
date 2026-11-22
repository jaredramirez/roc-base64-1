## Base64 encoding and decoding as per RFC 4648.
##
## `encode`/`decode` use the standard alphabet (`+`, `/`) with `=` padding.
## `encode_url`/`decode_url` use the URL-safe alphabet (`-`, `_`) without
## padding, as used in URLs, JWTs etc.
##
## Decoding is strict: any character outside the alphabet is rejected
## (including whitespace), padding must be well-formed when present, and both
## decoders accept unpadded input.

## Errors that can occur when decoding:
##
## - `InvalidLength` the input length can't come from base64 output (4n + 1
##    characters after removing padding).
## - `InvalidCharacter` a character outside the alphabet (or a misplaced `=`).
## - `InvalidPadding` a padded input whose length is not a multiple of four.
DecodeError : [
	InvalidLength,
	InvalidCharacter,
	InvalidPadding,
]

Base64 := [].{

	## Encode bytes with the standard alphabet, padded with `=`.
	##
	## ```roc
	## Base64.encode("foobar".to_utf8())  # "Zm9vYmFy"
	## Base64.encode("fo".to_utf8())      # "Zm8="
	## Base64.encode([])                  # ""
	## ```
	encode : List(U8) -> Str
	encode = |bytes| encode_with(bytes, standard, Bool.True)

	## Encode bytes with the URL-safe alphabet (`-` and `_`), unpadded.
	##
	## ```roc
	## Base64.encode_url("fo".to_utf8())      # "Zm8"
	## Base64.encode_url([0xFF, 0xEF, 0xBE])  # "_---"
	## ```
	encode_url : List(U8) -> Str
	encode_url = |bytes| encode_with(bytes, url_safe, Bool.False)

	## Decode standard-alphabet base64. Padded and unpadded inputs are both
	## accepted, and when padding is present it must be well-formed.
	##
	## ```roc
	## Base64.decode("Zm9vYmFy")  # Ok("foobar".to_utf8())
	## Base64.decode("Zm8=")      # Ok("fo".to_utf8())
	## Base64.decode("Zm8")       # Ok("fo".to_utf8())
	## Base64.decode("Zm 8")      # Err(InvalidCharacter)
	## ```
	decode : Str -> Try(List(U8), DecodeError)
	decode = |text| decode_with(text, standard)

	## Decode URL-safe base64. Padded and unpadded inputs are both accepted.
	##
	## ```roc
	## Base64.decode_url("_---")  # Ok([0xFF, 0xEF, 0xBE])
	## ```
	decode_url : Str -> Try(List(U8), DecodeError)
	decode_url = |text| decode_with(text, url_safe)
}

# --- Encode ---

encode_with : List(U8), Alphabet, Bool -> Str
encode_with = |bytes, alphabet, pad| {
	# SIMD for the bulk, then `encode_loop` for the rest
	out = List.with_capacity((bytes.len() / 3 + 1) * 4)
	(simd_out, pos) = encode_chunks(bytes, out, alphabet.encode_offsets)
	encoded = encode_loop(bytes, pos, alphabet.char62, alphabet.char63, pad, simd_out)
	match Str.from_utf8(encoded) {
		Ok(s) => s

		# Unreachable: sextet_char and the SIMD offsets only produce ASCII
		Err(_) => ""
	}
}

encode_loop : List(U8), U64, U8, U8, Bool, List(U8) -> List(U8)
encode_loop = |bytes, pos, char62, char63, pad, out|
	if pos + 3 <= bytes.len() {
		b0 = (bytes.get(pos) ?? 0).to_u32()
		b1 = (bytes.get(pos + 1) ?? 0).to_u32()
		b2 = (bytes.get(pos + 2) ?? 0).to_u32()
		group = b0.shl_wrap(16).bitwise_or(b1.shl_wrap(8)).bitwise_or(b2)
		encode_loop(
			bytes,
			pos + 3,
			char62,
			char63,
			pad,
			out
				.append(sextet_char(group.shr_wrap(18).bitwise_and(63), char62, char63))
				.append(sextet_char(group.shr_wrap(12).bitwise_and(63), char62, char63))
				.append(sextet_char(group.shr_wrap(6).bitwise_and(63), char62, char63))
				.append(sextet_char(group.bitwise_and(63), char62, char63)),
		)
	} else if pos + 2 == bytes.len() {
		b0 = (bytes.get(pos) ?? 0).to_u32()
		b1 = (bytes.get(pos + 1) ?? 0).to_u32()
		group = b0.shl_wrap(16).bitwise_or(b1.shl_wrap(8))
		with_chars =
			out
				.append(sextet_char(group.shr_wrap(18).bitwise_and(63), char62, char63))
				.append(sextet_char(group.shr_wrap(12).bitwise_and(63), char62, char63))
				.append(sextet_char(group.shr_wrap(6).bitwise_and(63), char62, char63))
		if pad {
			with_chars.append(61)
		} else {
			with_chars
		}
	} else if pos + 1 == bytes.len() {
		b0 = (bytes.get(pos) ?? 0).to_u32()
		group = b0.shl_wrap(16)
		with_chars =
			out
				.append(sextet_char(group.shr_wrap(18).bitwise_and(63), char62, char63))
				.append(sextet_char(group.shr_wrap(12).bitwise_and(63), char62, char63))
		if pad {
			with_chars.append(61).append(61)
		} else {
			with_chars
		}
	} else {
		out
	}

# The alphabet is computed arithmetically (A-Z, a-z, 0-9, then the two
# alphabet-specific characters) rather than via a lookup table. At the time
# of writing, a top-level List(U8) is a heap value read through bounds-checked
# `List.get`, not an inlined static array, so a table version benchmarks ~1.5x slower
# than these register-only branches. Arithmetic also keeps both alphabets on one
# code path, parameterized by char62/char63. If the performance characteristics
# change in the future we may switch to a lookup table.
sextet_char : U32, U8, U8 -> U8
sextet_char = |sextet, char62, char63|
	if sextet <= 25 {
		65 + sextet.to_u8_wrap()
	} else if sextet <= 51 {
		97 + (sextet - 26).to_u8_wrap()
	} else if sextet <= 61 {
		48 + (sextet - 52).to_u8_wrap()
	} else if sextet == 62 {
		char62
	} else {
		char63
	}

# --- Decode ---

decode_with : Str, Alphabet -> Try(List(U8), DecodeError)
decode_with = |text, alphabet| {
	chars = text.to_utf8()
	body_len = padded_body_length(chars)?
	remainder = body_len % 4
	if remainder == 1 {
		Err(InvalidLength)
	} else {
		# 16 characters at a time with SIMD until a chunk holds a character
		# outside the alphabet or fewer than 16 are left, then `decode_loop`
		# for the rest, which also reports any error. The extra 16 bytes of
		# capacity are room for the 4 bytes past each chunk's 12 that SIMD
		# writes before dropping them.
		out = List.with_capacity(body_len * 3 / 4 + 16)
		(simd_out, pos) = decode_chunks(chars, body_len, out, alphabet.decode_tables)
		decode_loop(chars, pos, body_len, alphabet.char62, alphabet.char63, simd_out)
	}
}

# Length of the input without trailing padding. Padding may be one or two
# trailing `=`. If any padding is present the total length must be a multiple
# of four. `=` anywhere else is caught as `InvalidCharacter` during decoding.
padded_body_length : List(U8) -> Try(U64, DecodeError)
padded_body_length = |chars| {
	len = chars.len()
	pad_count =
		if len >= 2 and chars.get(len - 1) == Ok(61) and chars.get(len - 2) == Ok(61) {
			2
		} else if len >= 1 and chars.get(len - 1) == Ok(61) {
			1
		} else {
			0
		}
	if pad_count > 0 and len % 4 != 0 {
		Err(InvalidPadding)
	} else {
		Ok(len - pad_count)
	}
}

decode_loop : List(U8), U64, U64, U8, U8, List(U8) -> Try(List(U8), DecodeError)
decode_loop = |chars, pos, body_len, char62, char63, out|
	if pos + 4 <= body_len {
		s0 = sextet_value(chars.get(pos) ?? 61, char62, char63)?
		s1 = sextet_value(chars.get(pos + 1) ?? 61, char62, char63)?
		s2 = sextet_value(chars.get(pos + 2) ?? 61, char62, char63)?
		s3 = sextet_value(chars.get(pos + 3) ?? 61, char62, char63)?
		group = s0.shl_wrap(18).bitwise_or(s1.shl_wrap(12)).bitwise_or(s2.shl_wrap(6)).bitwise_or(s3)
		decode_loop(
			chars,
			pos + 4,
			body_len,
			char62,
			char63,
			out
				.append(group.shr_wrap(16).bitwise_and(0xFF).to_u8_wrap())
				.append(group.shr_wrap(8).bitwise_and(0xFF).to_u8_wrap())
				.append(group.bitwise_and(0xFF).to_u8_wrap()),
		)
	} else if pos + 3 == body_len {
		s0 = sextet_value(chars.get(pos) ?? 61, char62, char63)?
		s1 = sextet_value(chars.get(pos + 1) ?? 61, char62, char63)?
		s2 = sextet_value(chars.get(pos + 2) ?? 61, char62, char63)?
		group = s0.shl_wrap(18).bitwise_or(s1.shl_wrap(12)).bitwise_or(s2.shl_wrap(6))
		Ok(
			out
				.append(group.shr_wrap(16).bitwise_and(0xFF).to_u8_wrap())
				.append(group.shr_wrap(8).bitwise_and(0xFF).to_u8_wrap()),
		)
	} else if pos + 2 == body_len {
		s0 = sextet_value(chars.get(pos) ?? 61, char62, char63)?
		s1 = sextet_value(chars.get(pos + 1) ?? 61, char62, char63)?
		group = s0.shl_wrap(18).bitwise_or(s1.shl_wrap(12))
		Ok(out.append(group.shr_wrap(16).bitwise_and(0xFF).to_u8_wrap()))
	} else {
		Ok(out)
	}

sextet_value : U8, U8, U8 -> Try(U32, DecodeError)
sextet_value = |char, char62, char63|
	if char >= 65 and char <= 90 {
		Ok((char - 65).to_u32())
	} else if char >= 97 and char <= 122 {
		Ok((char - 97 + 26).to_u32())
	} else if char >= 48 and char <= 57 {
		Ok((char - 48 + 52).to_u32())
	} else if char == char62 {
		Ok(62)
	} else if char == char63 {
		Ok(63)
	} else {
		Err(InvalidCharacter)
	}

# --- SIMD ---
#
# Encoding and decoding use 16-byte vectors for the bulk of the input,
# following Wojciech Muła and Daniel Lemire, "Faster Base64 Encoding and
# Decoding using AVX2 Instructions" (2018, https://arxiv.org/abs/1704.00605),
# with 16-byte vectors instead of 32. Roc lowers them to SSE/AVX on x86-64,
# NEON on ARM and simd128 on wasm32, and to scalar code on targets without
# SIMD (`x64v1`, `wasm32v1`). The scalar loops above handle every tail and
# report every error.

## The characters for 62 and 63, and the SIMD tables for an alphabet
Alphabet : { char62 : U8, char63 : U8, encode_offsets : U8x16, decode_tables : DecodeTables }

standard : Alphabet
standard = alphabet(43, 47)

url_safe : Alphabet
url_safe = alphabet(45, 95)

alphabet : U8, U8 -> Alphabet
alphabet = |char62, char63| {
	char62,
	char63,
	encode_offsets: encode_offsets(char62, char63),
	decode_tables: decode_tables(char62, char63),
}

## Read 16 bytes at `start`, which the caller has checked are there
load16 : List(U8), U64 -> U8x16
load16 = |bytes, start|
	match U8x16.load(bytes, start) {
		Ok(v) => v
		Err(OutOfBounds) => crash "load16 needs start + 16 <= len"
	}

## A vector from a list of exactly 16 lanes
vector : List(U8) -> U8x16
vector = |lanes|
	match U8x16.from_list(lanes) {
		Ok(v) => v
		Err(WrongLength) => crash "vector needs exactly 16 lanes"
	}

## A 32-bit constant in every lane, viewed as 16-bit lanes
splat32 : U32 -> U16x8
splat32 = |n| U32x4.splat(n).to_u8x16_bits().to_u16x8_bits()

## Encode the first 12 bytes of `input` as 16 characters
encode12 : U8x16, U8x16 -> U8x16
encode12 = |input, offsets| {
	# Each group of 3 bytes [a, b, c] becomes the 32-bit lane [b, a, c, b],
	# so every 6-bit value sits within one 16-bit half
	shuffled = input.table_lookup(encode_shuffle).to_u16x8_bits()
	# Move each half's two values into the low 6 bits of their own bytes
	hi = shuffled.bitwise_and(splat32(0x0FC0FC00)).times_high(splat32(0x04000040))
	lo = shuffled.bitwise_and(splat32(0x003F03F0)).times_wrap(splat32(0x01000010))
	values = hi.bitwise_or(lo).to_u8x16_bits()
	# Map 0..63 to the alphabet by adding an offset per range: 0..25 use
	# index 13, 26..51 index 0, 52..61 indices 1..10, and 62 and 63 indices
	# 11 and 12
	reduced = values.minus_saturated(U8x16.splat(51))
	upper = values.lt_lanes(U8x16.splat(26)).bitwise_and(U8x16.splat(13))
	values.plus_wrap(offsets.table_lookup(reduced.bitwise_or(upper)))
}

encode_shuffle : U8x16
encode_shuffle = vector([1, 0, 2, 1, 4, 3, 5, 4, 7, 6, 8, 7, 10, 9, 11, 10])

## What to add to each range of values to reach its character; see `encode12`
encode_offsets : U8, U8 -> U8x16
encode_offsets = |char62, char63| {
	# 'a' - 26, '0' - 52 for each of the ten digits, then the two
	# alphabet-specific characters, then 'A'
	vector(
		[71]
			.concat(List.repeat((48.U8).minus_wrap(52), 10))
			.concat([char62.minus_wrap(62), char63.minus_wrap(63), 65, 0, 0]),
	)
}

## Encode `bytes` 12 at a time while a whole 16-byte vector can be loaded,
## appending to `out`. Returns the output and how many bytes were encoded.
encode_chunks : List(U8), List(U8), U8x16 -> (List(U8), U64)
encode_chunks = |bytes, out, offsets| {
	var $out = out
	var $pos = 0
	while $pos + 16 <= bytes.len() {
		$out = encode12(load16(bytes, $pos), offsets).append_to($out)
		$pos = $pos + 12
	}
	($out, $pos)
}

## Decode `chars` up to `end`, 16 at a time, appending to `out`, until a
## chunk holds a character outside the alphabet or fewer than 16 are left.
## Returns the output and where decoding stopped, always a whole number of
## 4-character groups from the start.
decode_chunks : List(U8), U64, List(U8), DecodeTables -> (List(U8), U64)
decode_chunks = |chars, end, out, tables| {
	var $out = out
	var $pos = 0
	while $pos + 16 <= end {
		decoded = decode16(load16(chars, $pos), tables)
		if !decoded.valid {
			break
		}
		$out = decoded.bytes.append_to($out).drop_last(4)
		$pos = $pos + 16
	}
	($out, $pos)
}

## Decode 16 characters into 12 bytes, in the first 12 lanes of `bytes`.
## `valid` says whether every character is in the alphabet; when one is not,
## `bytes` is meaningless.
decode16 : U8x16, DecodeTables -> { bytes : U8x16, valid : Bool }
decode16 = |input, tables| {
	hi = input.shr_zf_wrap(4)
	# A byte with high nibble `h` and low nibble `l` is in the alphabet when
	# `invalid_lo[l]` and `class_hi[h]` share no bits
	valid =
		tables.invalid_lo
			.table_lookup(input.bitwise_and(U8x16.splat(0x0F)))
			.bitwise_and(tables.class_hi.table_lookup(hi))
			.eq_lanes(U8x16.splat(0))
			.all_lanes_set()

	# Each character plus the offset for its high nibble gives its value;
	# char63 shares a high nibble with other characters, so it uses slot
	# nibble + 8
	is63 = input.eq_lanes(U8x16.splat(tables.char63))
	values = input.plus_wrap(tables.offsets.table_lookup(hi.bitwise_or(is63.bitwise_and(U8x16.splat(8)))))

	# Join each pair of values into 12 bits, then each pair of those into
	# the 24 bits of a group, and gather the 3 bytes of each group
	pairs = values.dot_pairs_saturated(decode_pair_weights).to_u8x16_bits().to_u32x4_bits()
	groups = pairs.bitwise_and(U32x4.splat(0xFFFF)).shl_wrap(12).bitwise_or(pairs.shr_zf_wrap(16))
	{ bytes: groups.to_u8x16_bits().table_lookup(decode_shuffle), valid }
}

DecodeTables : { invalid_lo : U8x16, class_hi : U8x16, offsets : U8x16, char63 : U8 }

decode_pair_weights : I8x16
decode_pair_weights = vector([64, 1, 64, 1, 64, 1, 64, 1, 64, 1, 64, 1, 64, 1, 64, 1]).to_i8x16_bits()

## The 3 bytes of each group's 24 bits, most significant first; indices of
## 16 or more give 0
decode_shuffle : U8x16
decode_shuffle = vector([2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, 255, 255, 255, 255])

## Each high nibble's bit: nibbles 0 and 1 (control characters, never
## valid) share bit 0, nibbles 2 to 7 get bits 1 to 6, and non-ASCII
## nibbles 8 to 15 share bit 7
nibble_class : U8 -> U8
nibble_class = |h|
	if h <= 1 {
		1
	} else if h <= 7 {
		(1.U8).shl_wrap(h - 1)
	} else {
		0x80
	}

## The tables for `decode16`, derived from `sextet_value` so the two always
## agree
decode_tables : U8, U8 -> DecodeTables
decode_tables = |char62, char63| {
	nibbles = List.from_iter((0.U8).until(16))
	invalid_lo = nibbles.map(
		|l| nibbles.fold(
			0.U8,
			|bits, h|
				match sextet_value(h.shl_wrap(4).bitwise_or(l), char62, char63) {
					Ok(_) => bits
					Err(_) => bits.bitwise_or(nibble_class(h))
				},
		),
	)
	# For each slot, the offset of the alphabet characters there, or 0
	offset_for = |slot|
		List.from_iter((0.U32).until(256))
			.map(|n| n.to_u8_wrap())
			.keep_if(|c| if (c == char63) slot == c.shr_zf_wrap(4) + 8 else slot == c.shr_zf_wrap(4))
			.fold(
				0.U8,
				|offset, c|
					match sextet_value(c, char62, char63) {
						Ok(v) => v.to_u8_wrap().minus_wrap(c)
						Err(_) => offset
					},
			)
	{
		invalid_lo: vector(invalid_lo),
		class_hi: vector(nibbles.map(nibble_class)),
		offsets: vector(nibbles.map(offset_for)),
		char63,
	}
}

# --- Tests ---

# RFC 4648 section 10 test vectors

expect Base64.encode([]) == ""

expect Base64.encode("f".to_utf8()) == "Zg=="

expect Base64.encode("fo".to_utf8()) == "Zm8="

expect Base64.encode("foo".to_utf8()) == "Zm9v"

expect Base64.encode("foob".to_utf8()) == "Zm9vYg=="

expect Base64.encode("fooba".to_utf8()) == "Zm9vYmE="

expect Base64.encode("foobar".to_utf8()) == "Zm9vYmFy"

expect Base64.decode("") == Ok([])

expect Base64.decode("Zg==") == Ok("f".to_utf8())

expect Base64.decode("Zm8=") == Ok("fo".to_utf8())

expect Base64.decode("Zm9v") == Ok("foo".to_utf8())

expect Base64.decode("Zm9vYg==") == Ok("foob".to_utf8())

expect Base64.decode("Zm9vYmE=") == Ok("fooba".to_utf8())

expect Base64.decode("Zm9vYmFy") == Ok("foobar".to_utf8())

# Unpadded input decodes too

expect Base64.decode("Zg") == Ok("f".to_utf8())

expect Base64.decode("Zm8") == Ok("fo".to_utf8())

expect Base64.decode("Zm9vYg") == Ok("foob".to_utf8())

# The characters that differ between the alphabets

expect Base64.encode([0xFF, 0xEF, 0xBE]) == "/+++"

expect Base64.decode("/+++") == Ok([0xFF, 0xEF, 0xBE])

expect Base64.encode_url([0xFF, 0xEF, 0xBE]) == "_---"

expect Base64.decode_url("_---") == Ok([0xFF, 0xEF, 0xBE])

# URL-safe encoding is unpadded

expect Base64.encode_url("f".to_utf8()) == "Zg"

expect Base64.encode_url("fo".to_utf8()) == "Zm8"

expect Base64.decode_url("Zg") == Ok("f".to_utf8())

# ...but decode_url also accepts padded input
expect Base64.decode_url("Zg==") == Ok("f".to_utf8())

expect Base64.decode_url("Zm8=") == Ok("fo".to_utf8())

# All byte values round-trip through both alphabets
expect {
	all_bytes = List.repeat(0, 256).map_with_index(|_, index| index.to_u8_wrap())
	Base64.decode(Base64.encode(all_bytes)) == Ok(all_bytes)
}

expect {
	all_bytes = List.repeat(0, 256).map_with_index(|_, index| index.to_u8_wrap())
	Base64.decode_url(Base64.encode_url(all_bytes)) == Ok(all_bytes)
}

# Every input length remainder (0, 1, 2 bytes over a group) round-trips
expect {
	bytes = "base64 round trip".to_utf8()
	Base64.decode(Base64.encode(bytes)) == Ok(bytes)
}

expect {
	bytes = "base64 round trips".to_utf8()
	Base64.decode(Base64.encode(bytes)) == Ok(bytes)
}

expect {
	bytes = "base64 round trip!!".to_utf8()
	Base64.decode(Base64.encode(bytes)) == Ok(bytes)
}

# Non-canonical trailing bits are accepted, not rejected. Only three of the
# final sextet's six bits carry data here, so `Zg` and `Zh` (which differ only
# in the discarded low bits) both decode to `f`. RFC 4648 section 3.5 permits
# this.
expect Base64.decode("Zh==") == Ok("f".to_utf8())

# Decode errors

# 4n + 1 characters can never come out of an encoder
expect Base64.decode("Z") == Err(InvalidLength)

expect Base64.decode("Zm9vY") == Err(InvalidLength)

# Characters outside the alphabet, including whitespace and wrong-alphabet
expect Base64.decode("Zm 8") == Err(InvalidCharacter)

expect Base64.decode("Zm\n8") == Err(InvalidCharacter)

expect Base64.decode("_---") == Err(InvalidCharacter)

expect Base64.decode_url("/+++") == Err(InvalidCharacter)

# `=` in the middle is not padding
expect Base64.decode("Zm=8") == Err(InvalidCharacter)

# Padding on a length that is not a multiple of four
expect Base64.decode("Zg=") == Err(InvalidPadding)

expect Base64.decode("Zm9vY==") == Err(InvalidPadding)

# The tests below guard the SIMD paths, which handle 12 input bytes (encoding)
# or 16 characters (decoding) at a time, by comparing them with a plain
# reference implementation at every length around those chunk sizes and
# placing every byte value in every lane of a chunk.

## A byte-at-a-time encoder to compare against
reference_encode : List(U8), Str, Bool -> List(U8)
reference_encode = |bytes, chars, pad| {
	alphabet_chars = chars.to_utf8()
	at = |n, shift|
		match alphabet_chars.get(n.shr_zf_wrap(shift).bitwise_and(63).to_u64()) {
			Ok(c) => c
			Err(OutOfBounds) => crash "six bits always index the alphabet"
		}
	padding = |count| if (pad) List.repeat(61, count) else []
	bytes.chunks_of(3).fold(
		[],
		|out, group|
			match group {
				[a, b, c] => {
					n = a.to_u32().shl_wrap(16).bitwise_or(b.to_u32().shl_wrap(8)).bitwise_or(c.to_u32())
					out.concat([at(n, 18), at(n, 12), at(n, 6), at(n, 0)])
				}
				[a, b] => {
					n = a.to_u32().shl_wrap(16).bitwise_or(b.to_u32().shl_wrap(8))
					out.concat([at(n, 18), at(n, 12), at(n, 6)]).concat(padding(1))
				}
				[a] => {
					n = a.to_u32().shl_wrap(16)
					out.concat([at(n, 18), at(n, 12)]).concat(padding(2))
				}
				_ => out
			},
	)
}

standard_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

url_safe_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

## `len` bytes that differ between positions and between calls with
## different `seed`s, covering every byte value
pattern : U64, U64 -> List(U8)
pattern = |len, seed| List.from_iter((0.U64).until(len)).map(|i| (i * 167 + seed * 31 + i / 7).to_u8_wrap())

## `list` with the item at `index` replaced
replace_at : List(U8), U64, U8 -> List(U8)
replace_at = |list, index, item| list.take_first(index).append(item).concat(list.drop_first(index + 1))

## The text of ASCII bytes
ascii : List(U8) -> Str
ascii = |bytes| Str.from_utf8(bytes) ?? crash "the tests only build ASCII"

lengths : List(U64)
lengths = List.from_iter((0.U64).until(100)).concat([127, 128, 129, 191, 192, 193, 255, 256, 257, 1000, 1023, 1024, 1025])

# Encoding matches the reference at every length, for both alphabets
expect lengths.all(
	|len|
		[0, 1, 2].all(
			|seed| {
				bytes = pattern(len, seed)
				Base64.encode(bytes).to_utf8() == reference_encode(bytes, standard_chars, Bool.True)
					and Base64.encode_url(bytes).to_utf8() == reference_encode(bytes, url_safe_chars, Bool.False)
			},
		),
)

# Decoding the reference output gives back the bytes at every length, padded
# and unpadded, for both alphabets
expect lengths.all(
	|len|
		[0, 1, 2].all(
			|seed| {
				bytes = pattern(len, seed)
				[Bool.True, Bool.False].all(
					|pad|
						Base64.decode(ascii(reference_encode(bytes, standard_chars, pad))) == Ok(bytes)
							and Base64.decode_url(ascii(reference_encode(bytes, url_safe_chars, pad))) == Ok(bytes),
				)
			},
		),
)

## The alphabet rotated by 0 to 15 places, one after another: 1024
## characters, all decoded by SIMD, with every character in every lane
rotations : Str -> List(U8)
rotations = |chars| {
	a = chars.to_utf8()
	List.from_iter((0.U64).until(16)).fold([], |text, k| text.concat(a.drop_first(k)).concat(a.take_first(k)))
}

# Every character of both alphabets decodes correctly in every lane
expect {
	text = rotations(standard_chars)
	Base64.decode(ascii(text)).map_ok(|bytes| reference_encode(bytes, standard_chars, Bool.True)) == Ok(text)
}

expect {
	text = rotations(url_safe_chars)
	Base64.decode_url(ascii(text)).map_ok(|bytes| reference_encode(bytes, url_safe_chars, Bool.True)) == Ok(text)
}

# The SIMD loops run: the tests above give the same results with or without
# them, so check how far they get directly
expect {
	text = rotations(standard_chars)
	(_, end) = decode_chunks(text, text.len(), [], standard.decode_tables)
	end == text.len()
}

expect {
	# An invalid character stops decoding at the start of its chunk
	text = replace_at(rotations(standard_chars), 40, 33)
	(_, end) = decode_chunks(text, text.len(), [], standard.decode_tables)
	end == 32
}

expect {
	# Fewer than 16 characters left are left to the scalar loop
	text = rotations(standard_chars).take_first(63)
	(decoded, end) = decode_chunks(text, text.len(), [], standard.decode_tables)
	end == 48 and reference_encode(decoded, standard_chars, Bool.True) == text.take_first(48)
}

expect {
	bytes = pattern(40, 3)
	(encoded, end) = encode_chunks(bytes, [], standard.encode_offsets)
	end == 36 and encoded == reference_encode(bytes.take_first(36), standard_chars, Bool.True)
}

# Every byte value is accepted or rejected correctly in every lane of a SIMD
# chunk, for both alphabets. Bytes that are not ASCII would make the `Str`
# invalid UTF-8, so the SIMD classification of 0x80..0xFF is covered by
# `decode_tables` deriving from `sextet_value`, and checked below.
classified_in_every_lane : Str, (Str -> Try(List(U8), DecodeError)) -> Bool
classified_in_every_lane = |chars, decoder| {
	valid = reference_encode(pattern(48, 7), chars, Bool.True)
	List.from_iter((0.U8).until(128)).all(
		|byte|
			List.from_iter((16.U64).until(32)).all(
				|position| {
					result = decoder(ascii(replace_at(valid, position, byte)))
					if chars.to_utf8().contains(byte) {
						result.map_ok(|bytes| reference_encode(bytes, chars, Bool.True)) == Ok(replace_at(valid, position, byte))
					} else {
						result == Err(InvalidCharacter)
					}
				},
			),
	)
}

expect classified_in_every_lane(standard_chars, Base64.decode)

expect classified_in_every_lane(url_safe_chars, Base64.decode_url)

# The SIMD tables reject every byte that `sextet_value` rejects, non-ASCII
# included
expect [standard, url_safe].all(
	|a|
		List.from_iter((0.U32).until(256)).all(
			|n| {
				byte = n.to_u8_wrap()
				input = U8x16.splat(byte)
				decoded = decode16(input, a.decode_tables)
				match sextet_value(byte, a.char62, a.char63) {
					Ok(value) => decoded.valid and decoded.bytes.get_lane(0) == value.to_u8_wrap().shl_wrap(2).bitwise_or(value.to_u8_wrap().shr_zf_wrap(4))
					Err(_) => !decoded.valid
				}
			},
		),
)

# A bad character at any position of a long input is rejected
expect {
	valid = reference_encode(pattern(96, 5), standard_chars, Bool.True)
	List.from_iter((0.U64).until(valid.len())).all(
		|position|
			[0, 10, 32, 33, 45, 61, 95, 46, 64, 91, 96, 123, 127].all(
				# `=` in the last two positions is padding
				|bad| (bad == 61 and position + 2 >= valid.len()) or Base64.decode(ascii(replace_at(valid, position, bad))) == Err(InvalidCharacter),
			),
	)
}

# Non-canonical trailing bits are still accepted after SIMD chunks. The
# last group is always decoded by the scalar loop, so this checks the
# hand-off.
expect {
	bytes = pattern(49, 13)
	text = reference_encode(bytes, standard_chars, Bool.True)
	# 49 bytes end in "xx==" after 64 characters; set the unused low bits
	last = text.get(65) ?? crash "the text has 68 characters"
	Base64.decode(ascii(replace_at(text, 65, last.bitwise_or(1)))) == Ok(bytes)
}
