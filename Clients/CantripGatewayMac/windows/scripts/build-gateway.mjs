// Bundles the Gateway interface (Preact + TypeScript) into dist/gateway, served by the main process.
import { build } from "esbuild";
import { cpSync, mkdirSync } from "node:fs";
import { createRequire } from "node:module";

const watch = process.argv.includes("--watch");
mkdirSync("dist/gateway", { recursive: true });
cpSync("src/gateway/index.html", "dist/gateway/index.html");
cpSync("src/gateway/settings.html", "dist/gateway/settings.html");
cpSync("assets/icon.png", "dist/gateway/icon.png");
// ONNX Runtime for the on-device speech model (ui/voice/worker.ts), served from the app rather than a
// CDN and resolved next to transformers.js so it matches the runtime it bundles. The loader is
// renamed .js so it's served as JavaScript.
const requireFromTransformers = createRequire(createRequire(import.meta.url).resolve("@huggingface/transformers"));
mkdirSync("dist/gateway/ort", { recursive: true });
cpSync(requireFromTransformers.resolve("onnxruntime-web/ort-wasm-simd-threaded.asyncify.wasm"), "dist/gateway/ort/ort-wasm-simd-threaded.asyncify.wasm");
cpSync(requireFromTransformers.resolve("onnxruntime-web/ort-wasm-simd-threaded.asyncify.mjs"), "dist/gateway/ort/ort-wasm-simd-threaded.asyncify.js");
const options = {
  entryPoints: {
    app: "src/gateway/main.tsx",
    settings: "src/gateway/settings.tsx",
    // Speech recognition worker and microphone worklet (ui/voice).
    "voice-worker": "src/gateway/ui/voice/worker.ts",
    "voice-capture": "src/gateway/ui/voice/capture-worklet.ts",
  },
  outdir: "dist/gateway",
  bundle: true,
  format: "esm",
  target: "chrome140",
  jsx: "automatic",
  jsxImportSource: "preact",
  loader: { ".css": "css" },
  minify: !watch,
  sourcemap: watch ? "inline" : false,
  legalComments: "none",
  logLevel: "warning",
};
if (watch) {
  const { context } = await import("esbuild");
  const ctx = await context(options);
  await ctx.watch();
} else {
  await build(options);
}
