// 한옥 마당 한국사 퀴즈 — 실시간 서버
// 채점과 타이머는 모두 서버가 결정한다. 클라이언트는 받은 시각에 맞춰 그리기만 한다.
import express from "express";
import { createServer } from "node:http";
import { Server } from "socket.io";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import QRCode from "qrcode";

import { Rooms } from "./rooms.js";
import { QUIZ, LEVELS, levelInfo } from "./questions.js";
import * as participation from "./participation.js";
import { lanAddresses, bestLanAddress } from "./net.js";
import { MAX_PLAYERS } from "../public/shared/consts.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const PORT = Number(process.env.PORT || 3000);
// 인터넷에 올렸을 때 QR이 그 주소를 가리키게 하려면 PUBLIC_URL을 지정한다.
const PUBLIC_URL = (process.env.PUBLIC_URL || "").replace(/\/$/, "");

const app = express();
const http = createServer(app);
const io = new Server(http, { pingTimeout: 20000, pingInterval: 8000 });
const rooms = new Rooms(io);

/* ---------------- 화면 ---------------- */
app.use(express.static(join(root, "public"), { extensions: ["html"] }));
app.get("/host", (_req, res) => res.sendFile(join(root, "public", "host", "index.html")));
app.get("/play", (_req, res) => res.sendFile(join(root, "public", "play", "index.html")));
app.get("/solo", (_req, res) => res.sendFile(join(root, "public", "solo", "index.html")));
app.get("/data/questions.json", (_req, res) => res.sendFile(join(root, "data", "questions.json")));

/* ---------------- 거드는 주소들 ---------------- */
// 학생이 들어올 주소. 인터넷에 올렸으면 그 주소, 부스에서는 노트북의 내부 IP.
function joinBase(req){
  if (PUBLIC_URL) return PUBLIC_URL;
  const host = req?.headers?.host || "";
  const hostname = host.split(":")[0];
  // 진행자가 localhost로 열었다면 학생 기기가 쓸 수 있는 내부 IP로 바꿔 준다.
  if (!hostname || hostname === "localhost" || hostname === "127.0.0.1") return `http://${bestLanAddress()}:${PORT}`;
  return `http://${host}`;
}

app.get("/api/info", (req, res) => {
  res.json({
    joinBase: joinBase(req),
    levels: LEVELS.map(levelInfo),
    maxPlayers: MAX_PLAYERS,
    todayTotal: participation.todayTotal(),
    lan: lanAddresses().map(a => a.address),
    rooms: rooms.size
  });
});

// QR 코드는 npm 패키지(qrcode)로 서버에서 SVG를 만들어 내려준다. 외부 CDN을 쓰지 않는다.
app.get("/api/qr", async (req, res) => {
  const text = String(req.query.text || "").slice(0, 300);
  if (!text) return res.status(400).send("text가 필요해요.");
  try {
    const svg = await QRCode.toString(text, { type: "svg", margin: 1, errorCorrectionLevel: "M" });
    res.type("image/svg+xml").set("Cache-Control", "no-store").send(svg);
  } catch (e) {
    res.status(500).send("QR 코드를 만들지 못했어요.");
  }
});

/* ---------------- 소켓 ---------------- */
io.on("connection", socket => {
  let myRoom = null;       // 이 소켓이 들어가 있는 방
  let myPlayer = null;     // 학생인 경우
  let isHost = false;

  const leaveRoom = () => {
    if (myRoom){ myRoom.disconnect(socket.id); socket.leave(myRoom.room); }
  };

  /* --- 진행자 --- */
  socket.on("host:create", (_payload, ack) => {
    const room = rooms.create();
    if (!room) return ack?.({ error: "방을 더 만들 수 없어요." });
    myRoom = room; isHost = true;
    room.hostSockets.add(socket.id);
    socket.join(room.room);
    ack?.({ code: room.code, hostToken: room.hostToken, joinBase: joinBase(socket.request), snapshot: room.snapshot() });
  });

  socket.on("host:resume", ({ code, hostToken } = {}, ack) => {
    const room = rooms.get(code);
    if (!room || room.hostToken !== hostToken) return ack?.({ error: "방을 찾을 수 없어요." });
    myRoom = room; isHost = true;
    room.hostSockets.add(socket.id);
    room.touch();
    socket.join(room.room);
    ack?.({ code: room.code, hostToken: room.hostToken, joinBase: joinBase(socket.request), snapshot: room.snapshot() });
  });

  const hostOnly = fn => (...args) => { if (isHost && myRoom && !myRoom.closed) fn(...args); };

  socket.on("host:setLevel", hostOnly(({ level } = {}) => myRoom.setLevel(level)));
  socket.on("host:start", hostOnly(() => myRoom.startGame()));
  socket.on("host:next", hostOnly(() => { if (myRoom.phase === "reveal") myRoom.nextQuestion(); }));
  socket.on("host:endGame", hostOnly(() => myRoom.endGame()));
  socket.on("host:kick", hostOnly(({ playerId } = {}) => myRoom.kick(playerId)));
  socket.on("host:close", hostOnly(() => myRoom.close()));

  /* --- 학생 --- */
  socket.on("play:join", ({ code, name, color, playerToken } = {}, ack) => {
    const room = rooms.get(code);
    if (!room || room.closed) return ack?.({ error: "그런 입장 코드가 없어요. 진행자 화면의 숫자를 다시 확인해 주세요." });
    const r = room.join({ name, color, playerToken, socketId: socket.id });
    if (r.error === "full") return ack?.({ error: `이 방은 ${MAX_PLAYERS}명까지만 들어올 수 있어요.` });
    myRoom = room; myPlayer = r.player;
    socket.join(room.room);
    ack?.({
      playerId: r.player.id, playerToken: r.player.token,
      name: r.player.name, color: r.player.color, score: r.player.score,
      rejoined: r.rejoined, snapshot: room.snapshot()
    });
    room.sendState();
  });

  socket.on("play:move", ({ x, y } = {}) => {
    if (!myRoom || !myPlayer || myRoom.closed) return;
    myRoom.move(myPlayer, x, y);
  });

  socket.on("play:lock", (_p, ack) => {
    if (!myRoom || !myPlayer || myRoom.closed) return ack?.({ ok: false });
    ack?.(myRoom.lock(myPlayer));
  });

  // 힌트는 물어본 학생에게만 간다.
  socket.on("play:hint", (_p, ack) => {
    if (!myRoom || !myPlayer || myRoom.closed) return ack?.({ hint: null });
    ack?.({ hint: myRoom.hintFor(myPlayer) });
  });

  socket.on("disconnect", leaveRoom);
});

/* ---------------- 켜기 ---------------- */
http.listen(PORT, "0.0.0.0", () => {
  const ip = bestLanAddress();
  const line = "─".repeat(52);
  console.log(`\n${line}`);
  console.log("  한국사 퀴즈 서버가 켜졌어요!");
  console.log(line);
  console.log(`  진행자 화면 (부스 노트북)   http://localhost:${PORT}/host`);
  if (PUBLIC_URL){
    console.log(`  학생 화면   (인터넷 주소)   ${PUBLIC_URL}/play`);
  } else {
    console.log(`  학생 화면   (학생 기기)     http://${ip}:${PORT}/play`);
    const others = lanAddresses().map(a => a.address).filter(a => a !== ip);
    if (others.length) console.log(`  (다른 주소로도 들어올 수 있어요: ${others.map(a => `http://${a}:${PORT}/play`).join(", ")})`);
  }
  console.log(`  혼자 하기   (비상용)        http://localhost:${PORT}/solo`);
  console.log(line);
  console.log("  끄려면 이 창에서 Ctrl + C 를 누르세요.\n");
});
