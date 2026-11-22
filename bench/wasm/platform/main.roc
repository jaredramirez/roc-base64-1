platform ""
	requires {
		bench! : U64, U64, U64 => U64
	}
	exposes [Clock]
	packages {}
	provides { "roc_bench": bench_for_host! }
	hosted {
		"roc_clock_now": Clock.now!,
	}
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			exports: ["run"],
		},
		wasm32v1: {
			inputs: ["host.wasm", app],
			exports: ["run"],
		},
	}

import Clock

bench_for_host! : U64, U64, U64 => U64
bench_for_host! = bench!
