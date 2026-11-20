export const priorities={low:'Низкий',normal:'Обычный',high:'Высокий',critical:'Критический'};
export const projectStatuses={planned:'Планируется',active:'В работе',paused:'Приостановлен',completed:'Завершён',cancelled:'Отменён'};
export const kinds={create_task:'Создать задачу',change_due:'Изменить срок',change_assignee:'Изменить ответственного',change_status:'Изменить статус',decision:'Зафиксировать решение'};
export function addDays(date,days){const d=new Date(date+'T12:00:00Z');d.setUTCDate(d.getUTCDate()+days);return d.toISOString().slice(0,10);}
export function meId(w){return w.settings[w.mode==='demo'?'demo_me_id':'me_id'];}
export function stages(w,project){return w.projects.find(p=>p.id===Number(project))?.stages||w.default_stages;}
export function stageKey(t){return `${t.project_id??'none'}:${t.stage_id}`;}
const has=(values,value)=>!values?.length||values.includes(String(value));
export function personMatches(values,id,me){return !values?.length||values.some(v=>v==='none'?id==null:v==='me'?me!=null&&id===me:String(id)===v);}
export function filterTasks(w,f={}){
 const today=w.today,me=meId(w),q=(f.q||'').trim().toLocaleLowerCase('ru');
 const archivedProjects=new Set(w.projects.filter(project=>project.archived).map(project=>project.id));
 return w.tasks.filter(t=>
  !archivedProjects.has(t.project_id)&&
  (!q||`${t.title} ${t.description||''}`.toLocaleLowerCase('ru').includes(q))&&
  has(f.projects,t.project_id??'none')&&personMatches(f.assignees,t.assignee_id,me)&&
  (!f.statuses?.length||f.statuses.includes(stageKey(t))||f.statuses.includes('kind:'+t.stage_kind))&&
  (!f.windowFrom||t.due_date>=f.windowFrom)&&(!f.windowTo||t.due_date<=f.windowTo)&&has(f.priorities,t.priority)&&(!f.missing||!t.assignee_id||!t.due_date)&&(!f.active||t.active)&&(!f.blocked||t.blocked)&&
  (!f.source||(f.source==='meeting'?(t.sources||[]).length>0:!(t.sources||[]).length))&&
  (!f.dues?.length||f.dues.some(d=>d==='overdue'?t.overdue:d==='none'?!t.due_date:d==='today'?t.due_date===today:d==='week'?t.due_date>=today&&t.due_date<=addDays(today,6):d==='due-soon'?!t.overdue&&!!t.due_date&&t.due_date>=today&&t.due_date<=addDays(today,6):d==='due-later'?!t.overdue&&!!t.due_date&&t.due_date>=addDays(today,7):d==='range'?!!t.due_date&&(!f.from||t.due_date>=f.from)&&(!f.to||t.due_date<=f.to):false))
 );
}
export function sortTasks(tasks,sort='due'){
 const ranks={critical:0,high:1,normal:2,low:3};return [...tasks].sort((a,b)=>{
  if(sort==='priority')return (ranks[a.priority]-ranks[b.priority])||a.title.localeCompare(b.title,'ru');
  if(sort==='created'||sort==='updated')return String(b[sort+'_at']).localeCompare(String(a[sort+'_at']));
  return String(a.due_date||'9999').localeCompare(String(b.due_date||'9999'))||String(a.due_time||'23:59').localeCompare(String(b.due_time||'23:59'))||(ranks[a.priority]-ranks[b.priority]);
 });
}
export function overview(w,f={}){
 const tasks=filterTasks(w,{projects:f.projects,assignees:f.assignees,active:true});
 const from=f.horizon==='range'?(f.from||w.today):w.today;
 const to=f.horizon==='today'?w.today:f.horizon==='range'?(f.to||'9999'):addDays(w.today,6);
 const upcoming=t=>!!t.due_date&&t.due_date>=from&&t.due_date<=to;
 return {overdue:tasks.filter(t=>t.overdue),today:tasks.filter(t=>!t.overdue&&t.due_date===w.today&&upcoming(t)),upcoming:tasks.filter(t=>!t.overdue&&t.due_date>w.today&&upcoming(t)),missing:tasks.filter(t=>!t.assignee_id||!t.due_date)};
}
export function boardGroups(w,tasks){
 const groups=new Map();for(const task of tasks){const key=task.project_id??'none';if(!groups.has(key))groups.set(key,{id:key,title:w.projects.find(p=>p.id===key)?.title||'Без проекта',stages:stages(w,key),tasks:[]});groups.get(key).tasks.push(task);}return [...groups.values()];
}
export function groupTasks(w,tasks,key){
 if(!key||key==='none')return [{title:'',tasks}];const groups=new Map();for(const task of tasks){const label=key==='project'?(w.projects.find(p=>p.id===task.project_id)?.title||'Без проекта'):key==='assignee'?(w.people.find(p=>p.id===task.assignee_id)?.name||'Не назначен'):task.stage_title; if(!groups.has(label))groups.set(label,[]);groups.get(label).push(task);}return [...groups].map(([title,tasks])=>({title,tasks}));
}
export function taskDefaults(w,project=null){return {title:'',description:'',project_id:project,assignee_id:null,author_id:meId(w)||null,stage_id:stages(w,project).find(s=>s.kind==='active').id,priority:'normal',due_date:null,due_time:null,blocked:false,blocked_reason:'',dependencies:[],sources:[]};}

// Names come from confirmed transcript assignments; voice suggestions stay separate.
export function orbitIdentity(segment){if(segment?.person_id!=null)return 'person:'+segment.person_id;if(segment?.speaker_status==='multiple')return 'multiple';return segment?.speaker_id?'speaker:'+segment.speaker_id:'unknown';}
export function orbitRoster(meeting,transcript,people){const rows=new Map();const add=(key,name,id=null)=>{if(!rows.has(key))rows.set(key,{key,name,person_id:id,duration_ms:0,segments:[]});return rows.get(key);};for(const id of meeting?.participants||[]){add('person:'+id,people.find(p=>p.id===id)?.name||'Участник',id);}for(const s of transcript?.segments||[]){const key=orbitIdentity(s),p=people.find(p=>p.id===s.person_id),name=s.person_name||p?.name||(key==='multiple'?'Несколько голосов':s.speaker_id?'Голос '+s.speaker_id:'Неизвестный голос');const row=add(key,name,s.person_id??null);row.duration_ms+=Math.max(0,s.end_ms-s.start_ms);row.segments.push(s);}return [...rows.values()];}
export function orbitAtTime(transcript,ms){const turns=(transcript?.segments||[]).filter(s=>s.start_ms<=ms&&s.end_ms>ms);if(!turns.length)return null;const keys=[...new Set(turns.map(orbitIdentity))];return keys.length===1?{key:keys[0],segment:turns[0]}:{key:'multiple',segment:null};}
export function orbitLiveHint(active,hint,allowSilence=false){if(active?.state!=='recording'||(!allowSilence&&!(active.level>.015))||hint?.status!=='candidate'||hint.person_id==null||hint.meeting_id!==active.meeting_id||hint.session_id!==active.session_id||!Number.isFinite(hint.age_ms)||hint.age_ms>=6500||!Number.isFinite(hint.end_ms)||hint.end_ms>active.saved_ms||active.saved_ms-hint.end_ms>6000)return null;return 'person:'+hint.person_id;}

export function transcriptParagraphs(segments) {
 const paragraphs=[];
 let current, previous;
 for(const segment of segments){
  if(!segment.text?.trim())continue;
  const suggested=segment.voice_suggestion?.status==='candidate'?segment.voice_suggestion.person_id:null;
  const speaker=segment.overlap_label?'overlap:'+segment.overlap_label:
   segment.person_id==null&&suggested!=null?'person:'+suggested:orbitIdentity(segment);
  const pause=previous ? segment.start_ms-previous.end_ms : 0;
  if(!current||speaker!==current.speaker||pause>=1600||(current.length>=420&&/[.!?…]$/.test(previous.text.trim()))||current.length>=850){
   current={speaker,segments:[],length:0};paragraphs.push(current);
  }
  current.segments.push(segment);current.length+=segment.text.length+1;previous=segment;
 }
 return paragraphs;
}
