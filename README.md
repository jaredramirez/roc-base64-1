# roc-base64

Base64 encoding and decoding as per RFC 4648. The standard alphabet with `=` padding, and the URL-safe alphabet (unpadded) as used in URLs, JWTs etc.

## Quick start

```roc
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
    base64: "https://github.com/niclas-ahden/roc-base64/releases/download/1.0.2/DQBxATK6BtaCWe56bCmkMgdKJR2Ym8NiZZLhYCAgtLac.tar.zst",
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

    decoded =
        match Base64.decode(encoded) {
            Ok(bytes) => Str.from_utf8(bytes) ?? "Invalid UTF-8"
            Err(e) => "Decode failed: ${Str.inspect(e)}"
        }
    Stdout.line!("Decoded: ${decoded}")?

    Ok({})
}
```

See [examples](examples) for a runnable program.

## Performance

Encoding and decoding use SIMD for the bulk of the input, following Wojciech
Muła and Daniel Lemire, ["Faster Base64 Encoding and Decoding using AVX2
Instructions"](https://arxiv.org/abs/1704.00605), with Roc's 16-byte vectors.
The results are identical to the scalar code, which still handles the last
few bytes and reports errors.

Fastest of 100–200 samples per call, before (1.0.2) and after SIMD, with
Roc 0.1.0_RC1 and `--opt=speed`: arm64 and WebAssembly (in Node.js 24) on an
Apple M5 Pro, x86-64 on a GitHub Actions runner (Xeon Platinum 8573C). The
x86-64 rows are the median of three such runs. A ratio below 1× is a
slowdown.

| Target | Input | Encode before | Encode after | Decode before | Decode after |
| --- | --- | ---: | ---: | ---: | ---: |
| native (arm64) | 1 MiB | 760 µs | **88 µs** (8.6×) | 865 µs | **100 µs** (8.7×) |
| native (arm64) | 64 B | 53 ns | **24 ns** (2.2×) | 45 ns | **20 ns** (2.3×) |
| x86-64 (AVX2, the default) | 1 MiB | 1847 µs | **258 µs** (7.2×) | 1475 µs | **201 µs** (7.3×) |
| x86-64 (AVX2, the default) | 64 B | 140 ns | **58 ns** (2.4×) | 103 ns | **49 ns** (2.1×) |
| `x64v1` (SSE2 only) | 1 MiB | 1704 µs | 1745 µs (0.98×) | 1585 µs | 1901 µs (0.83×) |
| `x64v1` (SSE2 only) | 64 B | 127 ns | 133 ns (0.95×) | 114 ns | 150 ns (0.76×) |
| `wasm32` (simd128) | 1 MiB | 1053 µs | 942 µs (1.1×) | 1053 µs | 967 µs (1.1×) |
| `wasm32` (simd128) | 64 B | 77 ns | 80 ns (0.96×) | 56 ns | 78 ns (0.72×) |
| `wasm32v1` (no SIMD) | 1 MiB | 1195 µs | 1247 µs (0.96×) | 1027 µs | 1741 µs (0.59×) |
| `wasm32v1` (no SIMD) | 64 B | 87 ns | 100 ns (0.87×) | 56 ns | 118 ns (0.47×) |

Roc gives x86-64 (AVX2 level by default) and ARM64 (NEON) native vector
instructions, and there it is much faster at every size. Elsewhere it costs:

- On `wasm32v1` and `x64v1` the vectors become scalar or partly scalar code.
  Decoding is 1.2–2.1× slower than the plain scalar loop, and encoding up to
  1.15× slower.
- On `wasm32` (simd128), Roc 0.1.0_RC1 compiles some of the vector
  operations lane by lane: the decoder's table lookups become one load per
  lane instead of `i8x16.swizzle`. Large inputs gain about 10%, but decoding
  small inputs, such as tokens in URLs, is about 1.4× slower.

The other backends, on 1 MiB on the M5 Pro:

| Backend | Encode before | Encode after | Decode before | Decode after |
| --- | ---: | ---: | ---: | ---: |
| `--opt=dev` | 28.9 ms | 7.6 ms (3.8×) | 34.8 ms | 9.8 ms (3.6×) |
| `--opt=size` | 2.65 ms | 2.01 ms (1.3×) | 2.15 ms | 2.11 ms (1.0×) |
| interpreter | 887 ms | 168 ms (5.3×) | 1121 ms | 235 ms (4.8×) |

See [bench](bench) to reproduce these.

## Documentation

View the brief API documentation at [https://niclas-ahden.github.io/roc-base64/](https://niclas-ahden.github.io/roc-base64/).
