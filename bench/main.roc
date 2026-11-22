app [main!] {
	base64: "../package/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
}

import pf.Monotonic
import pf.OsStr
import pf.Stderr
import pf.Stdout
import base64.Base64

## Usage: roc build --opt=speed --output=bench/bench bench/main.roc && ./bench/bench SIZE ITERATIONS
##
## Encodes and decodes SIZE bytes ITERATIONS times each, after two warm-up
## runs, and prints the fastest encode and decode in nanoseconds per call.
## bench/wasm/ runs the same measurement on WebAssembly.
main! : List(OsStr) => Try({}, _)
main! = |os_args|
	match os_args.map(OsStr.display).map(U64.from_str) {
		[Ok(size), Ok(iterations)] => {
			bytes = List.from_iter((0.U64).until(size)).map(|i| (i * 31 + 7).to_u8_wrap())
			text = Base64.encode(bytes)
			if Base64.decode(text) != Ok(bytes) {
				Stderr.line!("round trip failed")?
				return Err(Exit(1))
			}
			# Each sample times enough calls to cover 256 KiB, for timer resolution
			reps = if (size == 0) 1 else (262144 + size - 1) / size
			encode_ns = best!(iterations, reps, |{}| Base64.encode(bytes).to_utf8().len())
			decode_ns = best!(
				iterations,
				reps,
				|{}| match Base64.decode(text) {
					Ok(decoded) => decoded.len()
					Err(_) => 0
				},
			)
			Stdout.line!("${encode_ns.to_str()} ${decode_ns.to_str()}")?
			Ok({})
		}
		_ => {
			Stderr.line!("Usage: bench/main.roc SIZE ITERATIONS")?
			Err(Exit(1))
		}
	}

## The fastest of `iterations` samples of `reps` runs of `f`, in nanoseconds
## per run. Each run's output length is checked, so the work cannot be skipped.
best! : U64, U64, ({} -> U64) => U64
best! = |iterations, reps, f| {
	_warm1 = f({})
	_warm2 = f({})
	var $min = 0xFFFF_FFFF_FFFF_FFFF.U64
	for _ in List.from_iter((0.U64).until(iterations)) {
		start = Monotonic.now!()
		var $len = 0
		for _ in List.from_iter((0.U64).until(reps)) {
			$len = $len + f({})
		}
		ns = start.elapsed!().to_nanos() / reps
		if $len == 0 {
			crash "a run produced no output"
		}
		if ns < $min {
			$min = ns
		}
	}
	$min
}
