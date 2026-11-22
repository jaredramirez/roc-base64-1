# Benchmarks

Both programs time `Base64.encode` and `Base64.decode` on SIZE bytes and print
the fastest of ITERATIONS samples, in nanoseconds per call. Small sizes time
batches of calls covering 256 KiB per sample.

## Native

```sh
roc build --opt=speed --output=bench/bench bench/main.roc
./bench/bench 1048576 200
```

## WebAssembly

`wasm32` targets the simd128 proposal and `wasm32v1` targets WebAssembly 1.0,
with no SIMD. `bench/wasm/platform/host.zig` is a minimal host (an allocator
and a clock imported from JavaScript); `run.mjs` runs a build in Node.js.
Needs Zig 0.16 and Node.js.

```sh
cd bench/wasm/platform
mkdir -p targets/wasm32 targets/wasm32v1
zig build-obj host.zig -target wasm32-freestanding -mcpu=generic+simd128 -O ReleaseFast -fPIC -ffunction-sections -fdata-sections -femit-bin=targets/wasm32/host.wasm
zig build-obj host.zig -target wasm32-freestanding -mcpu=mvp -O ReleaseFast -fPIC -ffunction-sections -fdata-sections -fcompiler-rt -femit-bin=targets/wasm32v1/host.wasm
cd ..
roc build --opt=speed --target=wasm32 --output=simd128.wasm main.roc
roc build --opt=speed --target=wasm32v1 --output=v1.wasm main.roc
node run.mjs simd128.wasm 1048576 100
node run.mjs v1.wasm 1048576 100
```

## x86-64

`x86/run.sh BEFORE_DIR AFTER_DIR` benchmarks two checkouts on x86-64 Linux,
built for the default target (AVX2) and for `x64v1musl` (SSE2 only), and
prints a table. `.github/workflows/x86-bench.yml` runs it on a GitHub runner
against 1.0.2 when started from the Actions tab.
