//! A minimal wasm host for benchmarking: an allocator, a monotonic clock
//! imported from JS, and a `run` export that calls the app.
const std = @import("std");

extern "env" fn js_now_ns() f64;
extern "env" fn js_panic(ptr: [*]const u8, len: usize) noreturn;

const gpa = std.heap.wasm_allocator;

// Roc's dealloc gives no length, so each allocation is prefixed with its
// total size, in a header as large as the alignment (at least 16)
fn headerFor(alignment: usize) usize {
    return @max(alignment, 16);
}

fn rocAlloc(length: usize, alignment: usize) callconv(.c) *anyopaque {
    const h = headerFor(alignment);
    const total = length + h;
    const base = gpa.rawAlloc(total, std.mem.Alignment.fromByteUnits(h), 0) orelse @trap();
    const p = base + h;
    @as(*usize, @ptrCast(@alignCast(p - @sizeOf(usize)))).* = total;
    return p;
}

fn totalOf(p: [*]u8) usize {
    return @as(*usize, @ptrCast(@alignCast(p - @sizeOf(usize)))).*;
}

fn rocDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    const h = headerFor(alignment);
    const p: [*]u8 = @ptrCast(ptr);
    const total = totalOf(p);
    gpa.rawFree((p - h)[0..total], std.mem.Alignment.fromByteUnits(h), 0);
}

fn rocRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
    const h = headerFor(alignment);
    const p: [*]u8 = @ptrCast(ptr);
    const old_length = totalOf(p) - h;
    const fresh: [*]u8 = @ptrCast(rocAlloc(new_length, alignment));
    @memcpy(fresh[0..@min(old_length, new_length)], p[0..@min(old_length, new_length)]);
    rocDealloc(ptr, alignment);
    return fresh;
}

fn rocDbg(_: [*]const u8, _: usize) callconv(.c) void {}

fn rocExpectFailed(_: [*]const u8, _: usize) callconv(.c) void {}

fn rocCrashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    js_panic(bytes, len);
}

comptime {
    @export(&rocAlloc, .{ .name = "roc_alloc" });
    @export(&rocDealloc, .{ .name = "roc_dealloc" });
    @export(&rocRealloc, .{ .name = "roc_realloc" });
    @export(&rocDbg, .{ .name = "roc_dbg" });
    @export(&rocExpectFailed, .{ .name = "roc_expect_failed" });
    @export(&rocCrashed, .{ .name = "roc_crashed" });
}

export fn roc_clock_now() callconv(.c) u64 {
    return @intFromFloat(js_now_ns());
}

extern fn roc_bench(op: u64, size: u64, iterations: u64) callconv(.c) u64;

export fn run(op: u64, size: u64, iterations: u64) callconv(.c) u64 {
    return roc_bench(op, size, iterations);
}
