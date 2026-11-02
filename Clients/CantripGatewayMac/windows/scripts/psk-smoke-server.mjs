// Serves one HTTP-over-TLS-PSK endpoint with system Node (OpenSSL) and prints its port.
// Used by psk-smoke.cjs to prove Electron's BoringSSL client negotiates the host's suite.
import { createServer as createHTTPServer } from "node:http";
import { createServer as createTLSServer } from "node:tls";
import { createHash } from "node:crypto";

const token = process.argv[2];
const key = createHash("sha256").update(token, "utf8").digest();
const tls = createTLSServer({
  ciphers: "ECDHE-PSK-CHACHA20-POLY1305",
  minVersion: "TLSv1.2",
  maxVersion: "TLSv1.2",
  pskCallback: (_socket, identity) => (identity === "cantrip-remote-v1" ? key : null),
});
const http = createHTTPServer((request, response) => {
  response.writeHead(200, { "content-type": "text/plain" });
  response.end(`ok ${request.socket.getCipher().name}`);
});
tls.on("secureConnection", (socket) => http.emit("connection", socket));
tls.listen(0, "127.0.0.1", () => console.log(tls.address().port));
setTimeout(() => process.exit(0), 60000).unref();
