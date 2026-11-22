// Usage: node run.mjs app.wasm SIZE ITERATIONS -> "encode_ns decode_ns"
import { readFileSync } from "node:fs";
const [file, size, iterations] = process.argv.slice(2);
let memory;
const env = {
  js_now_ns: () => Number(process.hrtime.bigint()),
  js_panic: (ptr, len) => {
    throw new Error(new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len)));
  },
};
const { instance } = await WebAssembly.instantiate(readFileSync(file), { env });
memory = instance.exports.memory;
const run = (op) => instance.exports.run(BigInt(op), BigInt(size), BigInt(iterations));
console.log(`${run(0)} ${run(1)}`);
