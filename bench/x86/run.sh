#!/usr/bin/env bash
# Usage: bench/x86/run.sh BEFORE_DIR AFTER_DIR
#
# Benchmarks two checkouts of this repo on x86-64 Linux, each built for the
# default target (x64musl, which Roc compiles for x86-64-v3: AVX2) and for
# x64v1musl (the x86-64 baseline: SSE2 only, no pshufb). basic-cli doesn't
# list x64v1musl, so this uses a local copy of it with that target added; its
# host libraries are plain x86-64 and only the app code changes. Prints a
# markdown table of medians of 3 runs. Set BUILD_ONLY=1 to skip running.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
before=$(cd "$1" && pwd)
after=$(cd "$2" && pwd)
work=$(mktemp -d)
basic_cli=7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr

# Download basic-cli into the cache, then copy it and add x64v1musl
roc check "$here/../main.roc" >/dev/null
cached=$(find "${XDG_CACHE_HOME:-$HOME/.cache}/roc/packages" -maxdepth 1 -type d -name "$basic_cli" | head -1)
cp -R "$cached" "$work/basic-cli"
rm -f "$work/basic-cli"/*.tar.zst
cp -R "$work/basic-cli/targets/x64musl" "$work/basic-cli/targets/x64v1musl"
sed -i 's|^\t\tx64musl: { inputs: \(.*\) },$|&\n\t\tx64v1musl: { inputs: \1 },|' "$work/basic-cli/main.roc"
grep -q x64v1musl "$work/basic-cli/main.roc"

targets="x64musl x64v1musl"
for version in before after; do
	dir=${!version}
	sed -e "s|pf: platform \"https://[^\"]*\"|pf: platform \"./basic-cli/main.roc\"|" \
		-e "s|\"../package/main.roc\"|\"$dir/package/main.roc\"|" \
		"$here/../main.roc" >"$work/$version.roc"
	for target in $targets; do
		roc build --opt=speed --target="$target" --output="$work/$version-$target" "$work/$version.roc" >/dev/null
	done
done

# The baseline builds must not use SSSE3 or AVX, and the default ones must
for build in before-x64v1musl after-x64v1musl before-x64musl after-x64musl; do
	objdump -d "$work/$build" >"$work/$build.s"
done
for build in before-x64v1musl after-x64v1musl; do
	if grep -qE '\b(v?pshufb|v?pmaddubsw)\b|ymm' "$work/$build.s"; then
		echo "$build uses instructions above SSE2" >&2
		exit 1
	fi
done
# Roc's builtins already use pshufb on x86-64-v3 (UTF-8 validation), so
# look for pmaddubsw, which only the SIMD decoder uses
grep -qE '\bv?pmaddubsw\b' "$work/before-x64musl.s" && { echo "before-x64musl already has pmaddubsw" >&2; exit 1; }
grep -qE '\bv?pmaddubsw\b' "$work/after-x64musl.s" || { echo "after-x64musl has no pmaddubsw" >&2; exit 1; }

if [ "${BUILD_ONLY:-0}" = 1 ]; then
	echo "built: $(ls "$work" | tr '\n' ' ')"
	exit 0
fi

# Median of 3 runs of "encode_ns decode_ns"
median() {
	local bin=$1 size=$2 iterations=$3 field=$4
	for _ in 1 2 3; do "$bin" "$size" "$iterations"; done | awk -v f="$field" '{ print $f }' | sort -n | sed -n 2p
}

cpu=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')
echo "CPU: $cpu ($(nproc) cores; AVX2: $(grep -qw avx2 /proc/cpuinfo && echo yes || echo no))"
echo
echo "| Target | Input | Encode before | Encode after | Decode before | Decode after |"
echo "| --- | --- | ---: | ---: | ---: | ---: |"
for target in $targets; do
	label=$([ "$target" = x64musl ] && echo 'x86-64 default (AVX2)' || echo '`x64v1` (SSE2 only)')
	for size in 1048576 64; do
		iterations=$([ "$size" = 64 ] && echo 200 || echo 100)
		eb=$(median "$work/before-$target" $size $iterations 1)
		ea=$(median "$work/after-$target" $size $iterations 1)
		db=$(median "$work/before-$target" $size $iterations 2)
		da=$(median "$work/after-$target" $size $iterations 2)
		awk -v l="$label" -v s=$size -v eb=$eb -v ea=$ea -v db=$db -v da=$da 'BEGIN {
			if (s == 64) { u = "ns"; d = 1; n = "64 B" } else { u = "µs"; d = 1000; n = "1 MiB" }
			printf "| %s | %s | %.0f %s | %.0f %s (%.1fx) | %.0f %s | %.0f %s (%.1fx) |\n", l, n, eb/d, u, ea/d, u, eb/ea, db/d, u, da/d, u, db/da
		}'
	done
done
