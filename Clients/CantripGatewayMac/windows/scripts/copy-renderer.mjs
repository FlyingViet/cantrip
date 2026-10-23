// The settings page is plain HTML/CSS/JS; copy it next to the compiled main process.
import { cpSync, mkdirSync } from "node:fs";
mkdirSync("dist/renderer", { recursive: true });
cpSync("src/renderer", "dist/renderer", { recursive: true });
