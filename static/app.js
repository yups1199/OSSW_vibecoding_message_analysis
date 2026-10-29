const $ = id => document.getElementById(id);
const sample = `가상 친구들과 카카오톡 대화
저장한 날짜 : 2026-10-04
--------------- 2026년 10월 1일 목요일 ---------------
[하늘] [오전 9:00] 안녕 친구들 프로젝트 회의 하자
[바다] [오전 9:02] 좋아 프로젝트 회의 준비했어
[나무] [오전 9:03] 나도 좋아 자료 공유할게
두 번째 줄도 같은 메시지야
[하늘] [오전 9:05] 고마워 자료 확인할게
[바다] [오후 2:00] 점심 먹었어? 프로젝트 회의 시작하자
[나무] [오후 2:01] 좋아 준비됐어
--------------- 2026년 10월 2일 금요일 ---------------
[나무] [오전 10:00] 안녕 프로젝트 진행 어때
[하늘] [오전 10:03] 좋아 화면 완성했어
[바다] [오전 10:05] 고마워 테스트 시작할게
--------------- 2026년 10월 4일 일요일 ---------------
[바다] [오후 8:00] 프로젝트 발표 준비하자
[하늘] [오후 8:01] 좋아 발표 자료 공유할게
[나무] [오후 8:04] 고마워 함께 마무리하자`;
function el(tag, text, cls) { const e=document.createElement(tag); if(text!==undefined)e.textContent=text; if(cls)e.className=cls; return e; }
function status(text,error=false){$('status').textContent=text;$('status').className=error?'error':'';}
function bars(id, rows){const root=$(id);root.replaceChildren();const max=Math.max(1,...rows.map(x=>x.value));rows.forEach(x=>{const row=el('div',undefined,'bar-row'),cap=el('div',undefined,'bar-caption'),track=el('div',undefined,'track'),fill=el('div',undefined,'fill');cap.append(el('span',x.label),el('b',x.caption??`${x.value}회`));fill.style.width=`${x.value/max*100}%`;track.append(fill);row.append(cap,track);root.append(row);});}
function columns(id,rows){const root=$(id);root.replaceChildren();const wrap=id==='daily'?el('div',undefined,'columns'):root;if(wrap!==root)root.append(wrap);const max=Math.max(1,...rows.map(x=>x.value));rows.forEach(x=>{const col=el('div',undefined,'column');col.title=`${x.label}: ${x.value}개`;const bar=el('i');bar.style.height=`${x.value/max*125}px`;col.append(el('small',x.value),bar,el('span',x.label));wrap.append(col);});}
function chips(id,rows){$(id).replaceChildren(...(rows.length?rows.map(x=>el('span',`${x.label} · ${x.value}`, 'chip')):[el('p','분석할 단어가 없습니다.')]));}
function duration(n){return n<60?`${n}초`:`${(n/60).toFixed(1)}분`;}
function render(d){$('period').textContent=`${d.start.slice(0,10)} — ${d.end.slice(0,10)}`;$('metrics').replaceChildren(...[[d.total,'전체 메시지'],[d.participant_count,'참여자'],[d.active_days,'대화한 날짜'],[d.sessions,'시작된 대화']].map(([n,label])=>{const e=el('div',undefined,'metric');e.append(el('span',label),el('b',n.toLocaleString()));return e;}));$('notice').textContent=`안내·날짜 등 제외 ${d.ignored_lines}줄 / 날짜·시간 오류로 제외 ${d.invalid_lines}줄. 여러 줄 본문은 한 메시지로 셉니다.`;bars('participants',d.participants.map(p=>({label:p.name,value:p.count,caption:`${p.count}개 · ${p.ratio}%` })));bars('starts',d.participants.map(p=>({label:p.name,value:p.starts})));['daily','hourly','weekdays'].forEach(id=>columns(id,d[id]));chips('words',d.words);chips('phrases',d.phrases);$('replies').replaceChildren(...d.replies.map(r=>{const row=el('tr');[r.responder,r.to,r.count,duration(r.median_seconds),duration(r.average_seconds)].forEach(v=>row.append(el('td',v)));return row;}));if(!d.replies.length){const row=el('tr'),td=el('td','응답 시간 표본이 없습니다.');td.colSpan=5;row.append(td);$('replies').append(row);}$('method').textContent=`${d.session_minutes}분 이상 공백이면 새 대화입니다. 같은 대화에서 바로 앞의 다른 발신자 메시지와의 차이를 집계합니다. 실제 답장 대상이나 읽은 시간은 알 수 없습니다. 분 단위 기록이므로 0초도 가능하며 표본이 적으면 해석에 주의하세요. 단어 분석은 형태소 분석이 아닙니다.`;$('results').hidden=false;}
$('sample').onclick=()=>{$('file').value='';$('filename').textContent='가상의 3명 · 12개 메시지';$('text').value=sample;$('results').hidden=true;status('가상 대화를 불러왔습니다. 분석하기를 눌러 주세요.');};
$('text').oninput=()=>{$('file').value='';$('filename').textContent='';$('results').hidden=true;};
$('file').onchange=()=>{const file=$('file').files[0];$('results').hidden=true;if(!file)return;if(!/\.txt$/i.test(file.name)||file.size>5*1024*1024||!file.size){$('file').value='';status('비어 있지 않은 5 MiB 이하 TXT 파일을 선택해 주세요.',true);return;}$('text').value='';$('filename').textContent=`선택한 파일: ${file.name}`;status('파일을 선택했습니다. 분석하기를 눌러 주세요.');};
$('reset').onclick=()=>{$('file').value='';$('text').value='';$('filename').textContent='';$('results').hidden=true;$('metrics').replaceChildren();['participants','starts','daily','hourly','weekdays','words','phrases','replies'].forEach(id=>$(id).replaceChildren());$('period').textContent='';$('notice').textContent='';$('method').textContent='';status('입력과 결과를 지웠습니다.');};
$('analyze').onclick=async()=>{const file=$('file').files[0],text=$('text').value; if(!file&&!text.trim()){status('파일을 선택하거나 대화 내역을 입력해 주세요.',true);return;}const controls=['analyze','sample','reset','file','text','threshold'];controls.forEach(id=>$(id).disabled=true);$('results').hidden=true;status('대화의 리듬을 분석하고 있습니다…');const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),60000);try{const response=await fetch(`/api/analyze?session_minutes=${$('threshold').value}`,{method:'POST',headers:{'Content-Type':'text/plain'},body:file||text,signal:controller.signal});const data=await response.json();if(!response.ok)throw Error(data.detail||'분석에 실패했습니다.');render(data);status('분석을 완료했습니다. 아래에서 결과를 확인하세요.');$('results').scrollIntoView({behavior:'smooth'});}catch(error){status(error.name==='AbortError'?'분석 시간이 초과되었습니다. 더 작은 파일로 다시 시도해 주세요.':error.message,true);}finally{clearTimeout(timer);controls.forEach(id=>$(id).disabled=false);}};
