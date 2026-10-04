// 로컬에서 화면을 열어 보기 위한 아주 단순한 정적 서버.
// 실제 배포는 Vercel 이 정적 파일을 서비스하므로 이 파일은 개발용이다.
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join, extname, normalize } from "node:path";
import { networkInterfaces } from "node:os";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "public");
const PORT = Number(process.env.PORT || 3000);
const TYPES = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8", ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon", ".map": "application/json"
};
const PAGES = { "/": "index.html", "/host": "host/index.html", "/play": "play/index.html", "/solo": "solo/index.html" };

createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://x");
    let rel = PAGES[url.pathname] || normalize(url.pathname).replace(/^(\.\.[/\\])+/, "").replace(/^\//, "");
    let file = join(root, rel);
    try { if ((await stat(file)).isDirectory()) file = join(file, "index.html"); } catch {}
    const body = await readFile(file);
    res.writeHead(200, { "Content-Type": TYPES[extname(file)] || "application/octet-stream", "Cache-Control": "no-store" });
    res.end(body);
  } catch {
    res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("없는 주소예요.");
  }
}).listen(PORT, "0.0.0.0", () => {
  const ip = Object.values(networkInterfaces()).flat()
    .find(n => n && n.family === "IPv4" && !n.internal)?.address || "127.0.0.1";
  const line = "─".repeat(52);
  console.log(`\n${line}\n  한국사 퀴즈 (개발용 화면 서버)\n${line}`);
  console.log(`  진행자 화면   http://localhost:${PORT}/host`);
  console.log(`  학생 화면     http://${ip}:${PORT}/play`);
  console.log(`  혼자 하기     http://localhost:${PORT}/solo`);
  console.log(`${line}\n  실시간·채점은 Supabase 가 맡습니다. 끄려면 Ctrl + C.\n`);
});
