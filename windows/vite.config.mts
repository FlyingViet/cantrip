import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  build: {
    outDir: "dist/renderer",
    emptyOutDir: true,
    rollupOptions: {
      // The launcher, and the Cantrip Home window (home.ts).
      input: {
        main: fileURLToPath(new URL("index.html", import.meta.url)),
        home: fileURLToPath(new URL("home.html", import.meta.url)),
      },
    },
  },
});
