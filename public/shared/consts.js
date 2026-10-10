// 단일 파일(hanguksa-quiz-single.html)의 상수를 그대로 옮긴 것.
// 같은 값이 Postgres 함수(supabase/migrations/0002_geometry.sql)에도 들어 있다.

export const RANKS = [
  {min:0,   title:"천민", say:"이제 막 역사 여행을 시작했어요. 다시 풀면 금방 올라갈 수 있어요!"},
  {min:30, title:"양민", say:"조금씩 알아가고 있어요. 해설을 다시 읽어 보면 더 잘할 수 있어요."},
  {min:50, title:"평민", say:"절반 넘게 맞혔어요! 우리 역사와 꽤 친해졌어요."},
  {min:70, title:"귀족", say:"대단해요! 역사 이야기를 많이 알고 있네요."},
  {min:90, title:"조선의 학자", say:"거의 다 맞혔어요! 집현전 학자도 놀랄 실력이에요."},
  {min:100,title:"왕", say:"모두 맞혔어요! 오늘 부스의 임금님이에요."}
];

export const NUMS = ["①","②","③","④"];
export const ROUND = 10;
export const TIME = {ox:22, mc:30};          // 문제당 제한 시간(초)
export const POINTS = 10;                    // 한 문제 맞히면 받는 점수(10문제 100점 만점)
// 저고리 색. 학생이 고르지 않고, 방에 들어오면 서버가 남은 색 중 하나를 겹치지 않게 골라 준다.
// 한 방 최대 인원(30명)만큼 있어야 한다. 같은 목록이 Postgres 함수 hq_colors() 에도 있다.
export const COLORS = [
  {id:"red",    label:"다홍",   css:"--red"},
  {id:"cheong", label:"청록",   css:"--cheong"},
  {id:"hwang",  label:"노랑",   css:"--hwang"},
  {id:"pink",   label:"분홍",   hex:"#e58fb0"},
  {id:"purple", label:"보라",   hex:"#7d5ba6"},
  {id:"sky",    label:"하늘",   hex:"#5aa9e6"},
  {id:"navy",   label:"남색",   hex:"#2c3e7a"},
  {id:"green",  label:"초록",   hex:"#4c9a3f"},
  {id:"lime",   label:"연두",   hex:"#a6c94a"},
  {id:"orange", label:"주황",   hex:"#e8833a"},
  {id:"brown",  label:"갈색",   hex:"#8a5a3b"},
  {id:"plum",   label:"자주",   hex:"#a33d6f"},
  {id:"mint",   label:"민트",   hex:"#7fd1b9"},
  {id:"lav",    label:"연보라", hex:"#b9a3e3"},
  {id:"coral",  label:"산호",   hex:"#f07c6c"},
  {id:"olive",  label:"올리브", hex:"#7a7a2e"},
  {id:"teal",   label:"옥색",   hex:"#2a9d9a"},
  {id:"lemon",  label:"레몬",   hex:"#f5e663"},
  {id:"rose",   label:"진분홍", hex:"#c2185b"},
  {id:"blue",   label:"파랑",   hex:"#1f6fd1"},
  {id:"meok",   label:"먹색",   hex:"#3a3a3a"},
  {id:"gray",   label:"회색",   hex:"#9a9a9a"},
  {id:"peach",  label:"살구",   hex:"#f6b38e"},
  {id:"wine",   label:"포도주", hex:"#6e1f2e"},
  {id:"forest", label:"진초록", hex:"#2e5d34"},
  {id:"cyan",   label:"물빛",   hex:"#3fc1d6"},
  {id:"violet", label:"진보라", hex:"#5b2a86"},
  {id:"tan",    label:"황토",   hex:"#c9a77c"},
  {id:"magenta",label:"꽃분홍", hex:"#d64fc0"},
  {id:"steel",  label:"청회색", hex:"#5c7a99"}
];
export const colorInfo = id => COLORS.find(c => c.id === id) || COLORS[0];

export const MAX_PLAYERS = 30;               // 한 방에 들어올 수 있는 학생 수
export const SPEED = 260;                    // 캐릭터 걷는 속도(px/초)

export const shuffle = arr => { const a = arr.slice(); for(let i=a.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1)); [a[i],a[j]]=[a[j],a[i]];} return a; };
export const esc = s => String(s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
export const rankOf = n => RANKS.filter(r => n >= r.min).pop();
