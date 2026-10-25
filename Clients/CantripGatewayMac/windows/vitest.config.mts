import { defineConfig } from "vitest/config";

// Component tests build Preact JSX, as the app bundle does (tsconfig.gateway.json, scripts/build-gateway.mjs).
export default defineConfig({
  oxc: { jsx: { runtime: "automatic", importSource: "preact" } },
});
