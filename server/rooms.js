// 방 저장소. 데이터베이스를 쓰지 않고 메모리에만 둔다.
import { Room } from "./room.js";

const IDLE_MS = 15 * 60 * 1000;   // 아무도 없는 방은 15분 뒤 정리
const SWEEP_MS = 60 * 1000;

export class Rooms {
  constructor(io){
    this.io = io;
    this.map = new Map();         // code -> Room
    this.sweeper = setInterval(() => this.sweep(), SWEEP_MS);
    this.sweeper.unref?.();
  }

  newCode(){
    for (let i = 0; i < 500; i++){
      const code = String(1000 + Math.floor(Math.random() * 9000));
      if (!this.map.has(code)) return code;
    }
    return null;
  }

  create(){
    const code = this.newCode();
    if (!code) return null;
    const room = new Room(code, this.io, c => this.map.delete(c));
    this.map.set(code, room);
    console.log(`[방 ${code}] 새 방을 만들었어요. (지금 열린 방 ${this.map.size}개)`);
    return room;
  }

  get(code){ return this.map.get(String(code ?? "").trim()); }

  sweep(){
    for (const [code, room] of this.map){
      if (room.idleMs() > IDLE_MS){
        console.log(`[방 ${code}] 아무도 없어서 정리했어요.`);
        room.close("오래 쓰지 않아 방이 닫혔어요.");
        this.map.delete(code);
      }
    }
  }

  get size(){ return this.map.size; }
}
