// Run with Electron after `npm run build`: npx electron scripts/psk-smoke.cjs
// Electron's main process (BoringSSL) sends one request over TLS-PSK to an OpenSSL server.
const { app } = require("electron");
const { spawn } = require("node:child_process");
const path = require("node:path");
const { sendOverPSK, PSK_CIPHERS } = require("../dist/main/transport.js");

app.whenReady().then(async () => {
  const token = "s".repeat(40);
  const server = spawn(process.env.NODE_BINARY || "node", [path.join(__dirname, "psk-smoke-server.mjs"), token], {
    stdio: ["ignore", "pipe", "inherit"],
    shell: process.platform === "win32",
  });
  let code = 1;
  try {
    const port = await new Promise((resolve, reject) => {
      server.stdout.once("data", (data) => resolve(Number(String(data).trim())));
      server.once("exit", () => reject(new Error("The smoke server exited early.")));
    });
    const response = await sendOverPSK({ host: "127.0.0.1", port }, token, { method: "GET", path: "/smoke", headers: {} });
    const body = response.body.toString();
    console.log(`Electron ${process.versions.electron} on ${process.platform}-${process.arch}: HTTP ${response.status} "${body}"`);
    code = response.status === 200 && body === `ok ${PSK_CIPHERS}` ? 0 : 1;
  } catch (error) {
    console.error(`TLS-PSK smoke test failed: ${error.message}`);
  } finally {
    server.kill();
    app.exit(code);
  }
});
