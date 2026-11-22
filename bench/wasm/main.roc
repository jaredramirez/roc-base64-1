app [bench!] {
	base64: "../../package/main.roc",
	pf: platform "./platform/main.roc",
}

import pf.Clock
import base64.Base64

## op 0 times encoding and op 1 decoding SIZE bytes, returning the fastest of
## ITERATIONS samples in nanoseconds per call, or 0 if the round trip fails
bench! : U64, U64, U64 => U64
bench! = |op, size, iterations| {
	bytes = List.from_iter((0.U64).until(size)).map(|i| (i * 31 + 7).to_u8_wrap())
	text = Base64.encode(bytes)
	if Base64.decode(text) != Ok(bytes) {
		return 0
	}
	reps = if (size == 0) 1 else (262144 + size - 1) / size
	if op == 0 {
		best!(iterations, reps, |{}| Base64.encode(bytes).to_utf8().len())
	} else {
		best!(
			iterations,
			reps,
			|{}| match Base64.decode(text) {
				Ok(decoded) => decoded.len()
				Err(_) => 0
			},
		)
	}
}

best! : U64, U64, ({} -> U64) => U64
best! = |iterations, reps, f| {
	_warm1 = f({})
	_warm2 = f({})
	var $min = 0xFFFF_FFFF_FFFF_FFFF.U64
	for _ in List.from_iter((0.U64).until(iterations)) {
		start = Clock.now!()
		var $len = 0
		for _ in List.from_iter((0.U64).until(reps)) {
			$len = $len + f({})
		}
		ns = (Clock.now!() - start) / reps
		if $len == 0 {
			crash "a run produced no output"
		}
		if ns < $min {
			$min = ns
		}
	}
	$min
}
