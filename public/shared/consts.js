// 단일 파일(hanguksa-quiz-single.html)의 상수를 그대로 옮긴 것.
// 서버(server/*)와 브라우저(public/*)가 같은 파일을 가져다 쓴다.

export const RANKS = [
  {min:0,  title:"천민", say:"이제 막 역사 여행을 시작했어요. 다시 풀면 금방 올라갈 수 있어요!"},
  {min:3,  title:"양민", say:"조금씩 알아가고 있어요. 해설을 다시 읽어 보면 더 잘할 수 있어요."},
  {min:5,  title:"평민", say:"절반 넘게 맞혔어요! 우리 역사와 꽤 친해졌어요."},
  {min:7,  title:"귀족", say:"대단해요! 역사 이야기를 많이 알고 있네요."},
  {min:9,  title:"조선의 학자", say:"거의 다 맞혔어요! 집현전 학자도 놀랄 실력이에요."},
  {min:10, title:"왕", say:"모두 맞혔어요! 오늘 부스의 임금님이에요."}
];

export const NUMS = ["①","②","③","④"];
export const ROUND = 10;
export const TIME = {ox:12, mc:20};          // 문제당 제한 시간(초)
export const COLORS = [
  {id:"red",   label:"다홍",  css:"--red"},
  {id:"cheong",label:"청록",  css:"--cheong"},
  {id:"hwang", label:"노랑",  css:"--hwang"}
];

export const MAX_PLAYERS = 30;               // 한 방에 들어올 수 있는 학생 수
export const SPEED = 260;                    // 캐릭터 걷는 속도(px/초)

export const shuffle = arr => { const a = arr.slice(); for(let i=a.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1)); [a[i],a[j]]=[a[j],a[i]];} return a; };
export const esc = s => String(s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
export const rankOf = n => RANKS.filter(r => n >= r.min).pop();
