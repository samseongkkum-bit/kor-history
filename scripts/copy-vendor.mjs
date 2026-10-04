// npm으로 설치한 브라우저용 라이브러리를 public/vendor로 복사한다.
// 부스에 인터넷이 없어도 서버가 직접 제공하도록 CDN을 쓰지 않는다.
// (QR 코드는 서버에서 qrcode 패키지로 SVG를 만들어 내려주므로 여기에 없다.)
import { copyFileSync, mkdirSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "public", "vendor");
mkdirSync(out, { recursive: true });

const files = [
  ["node_modules/socket.io/client-dist/socket.io.min.js", "socket.io.min.js"],
  ["node_modules/socket.io/client-dist/socket.io.min.js.map", "socket.io.min.js.map"],
];

let missing = 0;
for (const [from, to] of files) {
  const src = join(root, from);
  if (!existsSync(src)) { console.warn("건너뜀(없음):", from); missing++; continue; }
  copyFileSync(src, join(out, to));
  console.log("복사:", to);
}
if (missing) console.warn("일부 파일을 찾지 못했습니다. `npm install`을 다시 실행해 보세요.");
