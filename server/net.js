// 부스 노트북의 내부 IP 주소를 찾는다. 학생 기기가 들어올 주소를 안내하는 데 쓴다.
import { networkInterfaces } from "node:os";

export function lanAddresses(){
  const out = [];
  for (const [name, list] of Object.entries(networkInterfaces())){
    for (const ni of list || []){
      if (ni.family !== "IPv4" || ni.internal) continue;
      out.push({ name, address: ni.address });
    }
  }
  // 192.168.x / 10.x 같은 집·학교 공유기 주소를 먼저 보여 준다.
  const score = a => (a.address.startsWith("192.168.") ? 0 : a.address.startsWith("10.") ? 1 : a.address.startsWith("172.") ? 2 : 3);
  return out.sort((a,b) => score(a) - score(b));
}

export const bestLanAddress = () => lanAddresses()[0]?.address || "127.0.0.1";
