import {VTaskService} from './service.mjs';
import {priorities,projectStatuses,kinds,addDays,meId,stages,stageKey,filterTasks,sortTasks,overview,boardGroups,groupTasks,taskDefaults,personMatches,orbitIdentity,orbitRoster,orbitAtTime,orbitLiveHint,transcriptParagraphs} from './domain.mjs';
const api=new VTaskService(),$=s=>document.querySelector(s);
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let prefs;try{prefs=JSON.parse(localStorage.getItem('vtask-ui-v2')||'{}');}catch{prefs={};}
prefs={section:'overview',demo:false,taskView:'list',projectView:'cards',taskFilters:{},projectFilters:{},overviewFilters:{horizon:'week'},sort:'due',group:'none',...prefs};
let editTranscriptMode=false;
let meetingTab='transcript',selectedOrbitPerson=null;
let W=null,H=null,meetingData=null,draft=null,dirty=false,selected=new Set(),projectTab='overview',lastKey='',recordKey='',toastTimer,refreshBusy=false,autoFollow=true,transcriptQuery='',matchIndex=0,busy=false,lastUndo=null;
const sections={overview:'Сегодня',projects:'Проекты',tasks:'Задачи',meetings:'Совещания',approvals:'На подтверждение',people:'Участники',processing:'Обработка',settings:'Настройки'};
const paths={overview:'M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z',projects:'M3 7V4h7l2 3h9v13H3z',tasks:'M4 6l2 2 4-4 M13 6h8 M4 13l2 2 4-4 M13 13h8 M4 20h6 M13 20h8',meetings:'M3 6h18v15H3z M7 3v6 M17 3v6 M3 11h18',approvals:'M12 3l9 4v6c0 5-9 9-9 9S3 18 3 13V7z M8 12l3 3 5-6',people:'M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0 M4 22v-4c0-5 16-5 16 0v4',processing:'M4 7h16 M4 12h12 M4 17h8 M18 15l4 3-4 3'};
const icon=k=>`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><path d="${paths[k]||paths.overview}" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
const person=id=>W?.people.find(p=>p.id===Number(id))?.name||'Не назначен';
const project=id=>W?.projects.find(p=>p.id===Number(id))?.title||'Без проекта';
const statusLabel=s=>({created:'Подготовка',recording:'Запись',completed:'Сохранено',failed:'Ошибка',pending:'В очереди',running:'Обрабатывается',starting:'Запускаем микрофон',stopping:'Сохраняем запись',paused:'Пауза'}[s]||s);
const time=ms=>{const n=Math.floor((ms||0)/1000);return `${String(Math.floor(n/60)).padStart(2,'0')}:${String(n%60).padStart(2,'0')}`;};
const timePrecise=ms=>time(ms)+'.'+String(Math.floor((ms||0)%1000)).padStart(3,'0');
function dateLabel(date){if(!date)return 'Без срока';return new Intl.DateTimeFormat('ru-RU',{day:'numeric',month:'short',year:'numeric',timeZone:'UTC'}).format(new Date(date+'T12:00:00Z'));}
function stamp(value){return new Intl.DateTimeFormat('ru-RU',{dateStyle:'medium',timeStyle:'short',timeZone:W?.settings.timezone||'Europe/Moscow'}).format(new Date(value));}
function deadline(t){return `<span class="deadline ${t.overdue?'overdue':''}">${t.overdue?'Просрочено · ':''}${esc(dateLabel(t.due_date))}${t.due_time?' · '+esc(t.due_time):''}</span>`;}
function savePrefs(){try{localStorage.setItem('vtask-ui-v2',JSON.stringify(prefs));}catch{}}
function flash(message,undo=null){clearTimeout(toastTimer);const box=$('#toast');box.hidden=false;box.textContent=message;if(undo){const button=document.createElement('button');button.textContent='Отменить';button.onclick=undo;box.append(button);}toastTimer=setTimeout(()=>box.hidden=true,undo?14000:5000);}
function error(message){$('#notice').hidden=false;$('#notice').textContent=humanError(message);}
function humanError(message){if(message.includes('capture helper not found'))return 'Адаптер микрофона не собран. Откройте «Настройки → Проверка установки»; сохранённые встречи не затронуты.';if(message.includes('Permission')||message.includes('permission denied'))return 'Нет разрешения на микрофон. Разрешите доступ в настройках конфиденциальности macOS и повторите запись.';if(message.includes('No space')||message.includes('space left'))return 'Закончилась свободная память диска. Уже сохранённые фрагменты доступны в карточке встречи.';return message;}
async function perform(fn,message='Сохранено',render=true){if(busy)throw Error('Дождитесь завершения предыдущего сохранения');busy=true;document.body.setAttribute('aria-busy','true');try{const result=await fn();$('#notice').hidden=true;await refresh(false);if(render)renderAll();if(message)flash(message);return result;}catch(e){error(e.message);throw e;}finally{busy=false;document.body.setAttribute('aria-busy','false');}}
function option(value,label,current){return `<option value="${esc(value)}" ${String(current??'')===String(value)?'selected':''}>${esc(label)}</option>`;}
function personOptions(current,empty='Не назначен'){return option('',empty,current)+W.people.map(p=>option(p.id,p.name,current)).join('');}
function projectOptions(current){return option('','Без проекта',current)+W.projects.map(p=>option(p.id,p.title,current)).join('');}
function empty(message,action='',label=''){return `<div class="empty"><p>${esc(message)}</p>${action?`<button class="primary" data-action="${action}">${esc(label)}</button>`:''}</div>`;}
function taskBadges(t){return `${t.blocked?'<span class="badge warning">Заблокировано</span>':''}<span class="badge ${t.stage_kind==='done'?'success':''}">${esc(t.stage_title)}</span>`;}
function smallTasks(tasks){return tasks.length?taskTable(sortTasks(tasks),false):empty('Сейчас здесь нет задач.');}
function taskTable(tasks,checkboxes=true){return `<div class="table-wrap" tabindex="0" aria-label="Список задач"><table class="data-table"><thead><tr>${checkboxes?`<th><input type="checkbox" data-select-group="${tasks.map(t=>t.id).join(',')}" aria-label="Выбрать все задачи этой группы"></th>`:''}<th>Задача</th><th>Проект</th><th>Ответственный</th><th>Статус</th><th>Срок</th><th>Приоритет</th></tr></thead><tbody>${tasks.map(t=>`<tr>${checkboxes?`<td><input type="checkbox" data-select-task="${t.id}" ${selected.has(t.id)?'checked':''} aria-label="Выбрать задачу ${esc(t.title)}"></td>`:''}<td><button class="task-title" data-task="${t.id}">${esc(t.title)}</button>${t.blocked?`<span class="inline-detail">Заблокировано: ${esc(t.blocked_reason)}</span>`:''}</td><td>${esc(project(t.project_id))}</td><td><span class="avatar" aria-hidden="true">${esc(t.assignee_id?person(t.assignee_id).slice(0,1):'—')}</span>${esc(person(t.assignee_id))}</td><td>${taskBadges(t)}</td><td>${deadline(t)}</td><td class="priority-${esc(t.priority)}">${priorities[t.priority]}</td></tr>`).join('')}</tbody></table></div>`;}
function setupNavigation(){
 $('#navigation').innerHTML=['overview','meetings','tasks','projects','approvals','people','processing'].map(k=>[k,sections[k]]).map(([key,title])=>`<button class="nav-item" data-nav="${key}">${icon(key)}<span>${title}</span><span class="nav-count" data-count="${key}" hidden></span></button>`).join('');
 const desktopNav=matchMedia('(min-width:851px)');
 const syncNavToggle=()=>{
   const expanded=desktopNav.matches?!document.body.classList.contains('sidebar-collapsed'):document.body.classList.contains('nav-open');
   const toggle=$('#navToggle');
   toggle.setAttribute('aria-expanded',String(expanded));
   toggle.setAttribute('aria-label',expanded?'Скрыть навигацию':'Открыть навигацию');
 };
 desktopNav.addEventListener('change',syncNavToggle);
 syncNavToggle();
 const palette=$('#commandPalette'), query=$('#commandQuery'), results=$('#commandResults');
 let paletteTrigger;
 const searchSections=()=>{
   const tokenize=text=>String(text??'').toLowerCase().replaceAll('ё','е').match(/[\p{L}\p{N}]+/gu)||[];
   const stem=word=>/^закуп/.test(word)?'закуп':/^ткан/.test(word)?'ткан':word;
   const similar=(a,b)=>stem(a)===stem(b)||(a.length>=5&&b.length>=5&&a.slice(0,-1)===b.slice(0,-1));
   const ignored=new Set('найди найдите найти покажи покажите выведи все задачу задачи задача поручение по теме исполнитель исполнителю для ранее запущенную была ее у на про в'.split(' '));
   const words=tokenize(query.value).filter(word=>!ignored.has(word));
   const projects=W?.projects||[];
   const projectIndex=words.findIndex(word=>/^проект(?:е|у|а)?$/.test(word));
   const scoped=projectIndex>=0?projects.map(project=>({project,name:tokenize(project.title)}))
     .filter(({name})=>name.length&&name.every((word,i)=>similar(word,words[projectIndex+1+i]||'')))
     .sort((a,b)=>b.name.length-a.name.length):[];
   const scope=scoped.filter(item=>item.name.length===scoped[0].name.length);
   const topic=projectIndex<0?words:scope.length?[...words.slice(0,projectIndex),...words.slice(projectIndex+1+scope[0].name.length)]:[];
   const sidebar=palette.classList.contains('assistant-drawer');
   const matches=(sidebar?[]:Object.entries(sections)).filter(([,label])=>label.toLowerCase().includes(query.value.trim().toLowerCase()));
   const foundProjects=projectIndex>=0?scope.map(item=>item.project):words.length?projects.filter(project=>words.every(word=>tokenize(project.title).some(term=>similar(word,term)))):[];
   const tasks=((words.length&&(projectIndex<0||scope.length))||(sidebar&&!query.value.trim())?(W?filterTasks(W):[]):[]).filter(task=>{
     if(!words.length)return task.active;
     if(scope.length&&!scope.some(item=>item.project.id===task.project_id))return false;
     const quotes=(task.sources||[]).map(source=>source.quote);
     const terms=tokenize([task.title,task.description,person(task.assignee_id),...quotes].join(' '));
     return topic.every(word=>terms.some(term=>similar(word,term)));
   });
   const pending=words.length&&(projectIndex<0||scope.length)?(W?.proposals||[]).filter(proposal=>{
     if(proposal.status!=='pending'||proposal.kind==='decision')return false;
     const target=(W.tasks||[]).find(task=>task.id===proposal.task_id);
     const projectId=proposal.project_id??target?.project_id??W.meetings?.find(m=>m.id===proposal.source?.meeting_id)?.project_id;
     if(scope.length&&!scope.some(item=>item.project.id===projectId))return false;
     const terms=tokenize([proposal.title,proposal.description,proposal.source?.quote,target?.title,
       person(proposal.proposed?.assignee_id??proposal.assignee_id??target?.assignee_id)].join(' '));
     return topic.every(word=>terms.some(term=>similar(word,term)));
   }):[];
   results.innerHTML=[
     ...tasks.map(task=>`<button type="button" data-command-task="${task.id}">${esc(task.title)}<small><span class="badge ${task.overdue?'danger':task.active?'success':''}">${task.overdue?'Просрочена':task.active?'Актуальна':'Неактивна'}</span> · ${esc(project(task.project_id))} · ${esc(person(task.assignee_id))} · ${deadline(task)}</small></button>`),
     ...(pending.length?['<h3>На подтверждение</h3>',...pending.map(proposal=>`<button type="button" data-command-proposal="${proposal.id}">${esc(proposal.title)}<small><span class="badge warning">На подтверждение</span></small></button>`)]:[]),
     ...foundProjects.map(item=>`<button type="button" data-command-project="${item.id}">Проект · ${esc(item.title)}</button>`),
     ...matches.map(([section,label])=>`<button type="button" data-command="${section}">${esc(label)}</button>`)
   ].join('')||'<p role="status">Ничего не найдено</p>';
 };
 const openPalette=(sidebar=false)=>{
   if(palette.open||$('#modal').open)return;
   paletteTrigger=document.activeElement;
   palette.classList.toggle('assistant-drawer',sidebar);
   $('#commandTitle').textContent=sidebar?'Ассистент':'Найти задачу или раздел';
   query.value='';searchSections();palette.showModal();query.focus();
 };
 $('#assistantButton').onclick=()=>openPalette(true);
 document.addEventListener('click',event=>{
   const trigger=event.target.closest('[data-assistant-search]');
   if(!trigger)return;
   openPalette(true);
 });
 $('#commandClose').onclick=()=>palette.close();
 const isBackdrop=event=>{
   const bounds=palette.getBoundingClientRect();
   return event.target===palette && (
     event.clientX<bounds.left || event.clientX>=bounds.right ||
     event.clientY<bounds.top || event.clientY>=bounds.bottom
   );
 };
 let pressedBackdrop=false;
 palette.addEventListener('pointerdown',event=>{pressedBackdrop=isBackdrop(event);});
 palette.addEventListener('pointercancel',()=>{pressedBackdrop=false;});
 palette.addEventListener('click',event=>{
   if(pressedBackdrop && isBackdrop(event))palette.close();
   pressedBackdrop=false;
 });
 palette.addEventListener('close',()=>{pressedBackdrop=false;});
 palette.addEventListener('close',()=>{if(document.activeElement===document.body)(paletteTrigger?.isConnected?paletteTrigger:$('#assistantButton')).focus();});
 query.oninput=searchSections;
 query.onkeydown=event=>{
   if(event.key==='ArrowDown'){event.preventDefault();results.querySelector('button')?.focus();}
   if(event.key==='Enter'){event.preventDefault();results.querySelector('button')?.click();}
 };
 results.onclick=event=>{
   const task=event.target.closest('[data-command-task]');
   if(task){palette.close();openTask(Number(task.dataset.commandTask));return;}
   const proposal=event.target.closest('[data-command-proposal]');
   if(proposal){palette.close();guard(()=>reviewProposal(Number(proposal.dataset.commandProposal)));return;}
   const project=event.target.closest('[data-command-project]');
   if(project){palette.close();navigate('projects',{project:Number(project.dataset.commandProject)});return;}
   const target=event.target.closest('[data-command]');
   if(target){palette.close();navigate(target.dataset.command);}
 };
 const SpeechRecognition=window.SpeechRecognition||window.webkitSpeechRecognition;
 const voiceButton=$('#commandVoice'), voiceStatus=$('#commandVoiceStatus');
 let recognition;
 voiceButton.disabled=!SpeechRecognition;
 if(!SpeechRecognition)voiceStatus.textContent='Голосовой ввод недоступен в этом браузере.';
 voiceButton.onclick=()=>{
   if(recognition)return;
   recognition=new SpeechRecognition();
   recognition.lang='ru-RU';
   recognition.onresult=event=>{query.value=event.results[0][0].transcript;searchSections();};
   recognition.onerror=()=>{voiceStatus.textContent='Не удалось распознать запрос. Введите его текстом или повторите.';};
   recognition.onend=()=>{recognition=null;voiceButton.disabled=false;if(voiceStatus.textContent==='Слушаю…')voiceStatus.textContent='';};
   voiceButton.disabled=true;
   voiceStatus.textContent='Слушаю…';
   try{recognition.start();}catch{recognition=null;voiceButton.disabled=false;voiceStatus.textContent='Микрофон недоступен.';}
 };
 palette.addEventListener('close',()=>recognition?.abort());
 document.addEventListener('keydown',event=>{
   if(event.metaKey&&!event.altKey&&event.key.toLowerCase()==='k'){event.preventDefault();openPalette();}
 });
 $('#navToggle').onclick=()=>{if(desktopNav.matches){document.body.classList.toggle('sidebar-collapsed');syncNavToggle();return;}const open=document.body.classList.toggle('nav-open');syncNavToggle();if(open)$('#navigation button').focus();};$('#navClose').onclick=()=>{document.body.classList.remove('nav-open');$('#navToggle').setAttribute('aria-expanded','false');$('#navToggle').focus();};
 $('#headerTheme').onchange=async e=>{const theme=e.target.value;try{await perform(()=>api.command('settings',{data:{theme}},prefs.demo),'Тема сохранена',false);applyAppearance();}catch{applyAppearance();}};
 $('#modeButton').onclick=()=>toggleDemo(!prefs.demo);$('#leaveDemo').onclick=()=>toggleDemo(false);
}
function renderNavigation(){for(const element of document.querySelectorAll('[data-nav]')){const active=element.dataset.nav===prefs.section;element.classList.toggle('active',active);active?element.setAttribute('aria-current','page'):element.removeAttribute('aria-current');}for(const [key,n] of Object.entries({tasks:filterTasks(W,{active:true}).length,approvals:W.proposals.filter(p=>p.status==='pending').length,processing:W.meetings.filter(m=>['pending','running'].includes(m.processing?.status)).length})){const element=$(`[data-count="${key}"]`);if(element){element.textContent=n;element.hidden=!n;}}$('#modeButton').textContent=prefs.demo?'Мои реальные данные':'Посмотреть демо';$('#demoBanner').hidden=!prefs.demo;}
function renderHeader(){const meeting=prefs.section==='meetings'&&prefs.meetingId?W.meetings.find(m=>m.id===prefs.meetingId):null;const title=prefs.section==='meetings'&&prefs.meetingId?W.meetings.find(m=>m.id===prefs.meetingId)?.title:prefs.section==='projects'&&prefs.projectId?project(prefs.projectId):sections[prefs.section];$('#pageTitle').textContent=title||sections[prefs.section];$('#breadcrumb').textContent=prefs.meetingId&&prefs.section==='meetings'?'Встречи / Карточка встречи':prefs.projectId&&prefs.section==='projects'?'Проекты / Рабочее пространство':'VTASK · '+(prefs.demo?'демонстрация':'мой компьютер');let buttons='';if(prefs.section==='meetings'&&prefs.meetingId)buttons='<button data-action="edit-meeting">Участники</button>';else if(['overview','meetings'].includes(prefs.section))buttons='<button class="primary" data-action="new-meeting">＋ Новая встреча</button>';if(['tasks','overview'].includes(prefs.section))buttons+='<button data-action="new-task">＋ Задача</button>';if(prefs.section==='tasks')buttons='<button class="primary" data-action="new-task">＋ Задача</button>';if(prefs.section==='projects')buttons=prefs.projectId?`<button data-edit-project="${prefs.projectId}">Изменить проект</button><button class="primary" data-action="new-task">＋ Задача</button>`:'<button class="primary" data-action="new-project">＋ Проект</button>';if(prefs.section==='people')buttons='<button class="primary" data-action="new-person">＋ Участник</button>';$('#pageActions').innerHTML=buttons;const subtitle=$('#meetingSubtitle');subtitle.hidden=!meeting;if(meeting){const count=meeting.participants?.length||0;subtitle.textContent=(meeting.project_id?project(meeting.project_id)+' · ':'')+count+' '+(new Intl.PluralRules('ru').select(count)==='one'?'участник':new Intl.PluralRules('ru').select(count)==='few'?'участника':'участников');}}
function renderRecordBar(){const active=H?.recording.active,bar=$('#recordingBar');bar.hidden=!active;if(!active){recordKey='';return;}const key=active.meeting_id+':'+active.state+':'+(H.free_bytes!=null&&H.free_bytes<500*1024**2);if(key!==recordKey){recordKey=key;bar.innerHTML=`<strong>● ${esc(statusLabel(active.state))}</strong><button class="link-button" data-meeting="${active.meeting_id}">${esc(W.meetings.find(m=>m.id===active.meeting_id)?.title||'Текущая встреча')}</button><span id="globalClock"></span><small id="globalLevelLabel"></small><span class="meter" role="meter" aria-label="Уровень микрофона" aria-valuemin="0" aria-valuemax="100"><span id="globalLevel"></span></span><small id="globalSaved"></small>${H.free_bytes!=null&&H.free_bytes<500*1024**2?'<span class="badge warning">Мало места на диске — сохранение может остановиться</span>':''}<span class="spacer"></span>${['recording','paused'].includes(active.state)?`<button data-record="${active.state==='paused'?'resume':'pause'}" data-id="${active.meeting_id}" ${active.can_pause?'':'disabled title="Обновите адаптер микрофона для паузы"'}>${active.state==='paused'?'Продолжить':'Пауза'}</button>`:''}<button class="danger" data-record="stop" data-id="${active.meeting_id}" ${active.state==='stopping'?'disabled':''}>Завершить запись</button>`;}
 $('#globalClock').textContent=time(active.elapsed_ms);$('#globalSaved').textContent='Сохранено до '+timePrecise(active.saved_ms);$('#globalLevelLabel').textContent=active.level==null?'Ожидаем уровень микрофона':'Микрофон';$('#globalLevel').parentElement.hidden=active.level==null;$('#globalLevel').style.width=(Math.min(100,(active.level||0)*250))+'%';$('#globalLevel').parentElement.setAttribute('aria-valuenow',Math.round(Math.min(100,(active.level||0)*250)));const circle=$('#circleClock');if(circle&&active.meeting_id===prefs.meetingId)circle.textContent=time(active.elapsed_ms);const live=$('#liveClock');if(live)live.textContent=time(active.elapsed_ms);
}
function applyAppearance(){document.documentElement.dataset.theme=W.settings.theme;$('#headerTheme').value=W.settings.theme;document.documentElement.style.setProperty('--base',W.settings.font_size+'px');}
function dataKey(){return JSON.stringify([W.tasks.map(t=>[t.id,t.revision,t.due_state]),W.projects.map(p=>[p.id,p.revision,p.overdue]),W.proposals.map(p=>[p.id,p.status]),W.people,H.voice_data,H.voice?.running,W.meetings.map(m=>[m.id,m.status,m.processing?.id,m.processing?.status,m.recordings.length,m.manual_notes?.revision,m.analysis?.id,m.analysis?.state]),H.groq]);}
let refreshDone=Promise.resolve();
async function refresh(render=true){
 if(render&&refreshBusy)return;
 while(refreshBusy)await refreshDone;
 let finish;
 refreshDone=new Promise(resolve=>{finish=resolve;});
 refreshBusy=true;try{[W,H]=await Promise.all([api.snapshot(prefs.demo),api.status()]);applyAppearance();renderNavigation();renderRecordBar();renderMicrophoneTest();renderVoicePersonStatus();renderVoiceCaptureStatus();renderMeetingCircleStatus();renderMeetingRecognitionStatus();const key=dataKey();const recordingThisMeeting=prefs.section==='meetings'&&H.recording.active?.meeting_id===prefs.meetingId&&!!$('#meetingControls');if(render&&key!==lastKey&&!recordingThisMeeting&&!dirty&&!$('#modal').open){renderAll();}lastKey=key;
 if(prefs.section==='meetings'&&prefs.meetingId&&!$('#modal').open){const marker=JSON.stringify([W.meetings.find(m=>m.id===prefs.meetingId),H.recording.active?.state,H.recording.last,H.final_waiting,H.auto_process_error,H.speech.running,H.live,H.voice,H.voice_data?.match_jobs,H.voice_data?.profiles,H.recording.active?.fragments]);if(marker!==window.meetingMarker){window.meetingMarker=marker;await loadMeeting(prefs.meetingId,true);}}
 }finally{refreshBusy=false;finish();}}
function preserveFocus(fn){const active=document.activeElement,id=active?.id,start=active?.selectionStart,end=active?.selectionEnd;fn();if(id){const next=document.getElementById(id);if(next){next.focus({preventScroll:true});if(typeof start==='number'&&next.setSelectionRange)try{next.setSelectionRange(start,end);}catch{}}}}
function renderAll(){if(!W)return;renderHeader();renderNavigation();renderRecordBar();preserveFocus(()=>{const views={overview:renderOverview,projects:renderProjects,tasks:()=>renderTasks(),meetings:renderMeetings,approvals:renderApprovals,people:renderPeople,processing:renderProcessing,settings:renderSettings};$('#main').innerHTML=views[prefs.section]();});bindView();if(prefs.section==='meetings'&&prefs.meetingId){if(meetingData?.meeting.id===prefs.meetingId)renderMeetingSections();else loadMeeting(prefs.meetingId).catch(e=>error(e.message));}if(prefs.selectedTask&&!draft){const task=W.tasks.find(t=>t.id===prefs.selectedTask);if(task){draft=structuredClone(task);renderInspector();}}}
function confirmUnsaved({save,discard}){
 const dialog=$('#unsavedDialog');
 if(dialog.open)return;
 const buttons=[...dialog.querySelectorAll('button')];
 const [stay,drop,apply]=buttons;
 const errorBox=dialog.querySelector('[role=alert]');
 errorBox.hidden=true;
 stay.onclick=()=>dialog.close();
 drop.onclick=()=>{dialog.close();discard();};
 dialog.oncancel=event=>{if(apply.disabled)event.preventDefault();};
 apply.onclick=async()=>{
   buttons.forEach(button=>button.disabled=true);
   errorBox.hidden=true;
   try{await save(dialog);}
   catch(err){errorBox.textContent=humanError(err.message);errorBox.hidden=false;}
   finally{buttons.forEach(button=>button.disabled=false);}
 };
 dialog.showModal();
 stay.focus();
}

async function guard(fn){
 if(!dirty)return fn();
 confirmUnsaved({
   discard:()=>{closeInspector();fn();},
   save:async dialog=>{await saveTaskDraft();dialog.close();fn();}
 });
}
function navigate(section,{meeting=null,project=null}={}){guard(()=>{selected.clear();prefs.section=section;meetingTab='transcript';prefs.meetingId=meeting;prefs.projectId=project;projectTab='overview';meetingData=null;editTranscriptMode=false;selectedOrbitPerson=null;window.meetingMarker='';autoFollow=true;savePrefs();document.body.classList.remove('nav-open');if(!matchMedia('(min-width:851px)').matches)$('#navToggle').setAttribute('aria-expanded','false');renderAll();history.pushState(null,'','#'+section+(meeting?'/'+meeting:project?'/'+project:''));$('#main').focus({preventScroll:true});});}
async function toggleDemo(demo){await guard(async()=>{if(demo)await perform(()=>api.command('seed_demo'),'',false);prefs.demo=demo;prefs.projectId=null;prefs.meetingId=null;prefs.selectedTask=null;draft=null;dirty=false;selected.clear();closeInspector();savePrefs();await refresh(false);renderAll();});}
function commonOverviewFilters(){const f=prefs.overviewFilters;return `<div class="filters"><label>Ответственный<select id="overviewAssignee">${option('','Все',f.assignees?.[0])}${option('me','Я',f.assignees?.[0])}${option('none','Не назначен',f.assignees?.[0])}${W.people.map(p=>option(p.id,p.name,f.assignees?.[0])).join('')}</select></label><label>Проект<select id="overviewProject">${option('','Все проекты',f.projects?.[0])}${W.projects.map(p=>option(p.id,p.title,f.projects?.[0])).join('')}</select></label><label>Горизонт планирования<select id="overviewHorizon">${option('today','Сегодня',f.horizon)}${option('week','Семь дней',f.horizon)}${option('range','Диапазон',f.horizon)}</select></label>${f.horizon==='range'?`<label>С даты<input id="overviewFrom" type="date" value="${esc(f.from||W.today)}"></label><label>По дату<input id="overviewTo" type="date" value="${esc(f.to||addDays(W.today,6))}"></label>`:''}</div>`;}
function todayTasks(items){return items.length?sortTasks(items).slice(0,5).map(t=>`<article class="today-task"><div><button class="task-title" data-task="${t.id}">${esc(t.title)}</button><p class="muted">${esc(person(t.assignee_id))} · ${esc(t.stage_title)}${t.blocked?' · Заблокировано':''}</p></div><span>${deadline(t)}</span></article>`).join(''):empty('На сегодня задач нет.');}
const expandedGanttGroups=new Set();
document.addEventListener('toggle',event=>{
 const group=event.target.dataset?.ganttGroup;
 if(group)event.target.open?expandedGanttGroups.add(group):expandedGanttGroups.delete(group);
},true);

const calendarPeriods={day:'День',week:'Неделя',month:'Месяц',year:'Год'};
let calendarDate=null;
function taskCalendar(tasks){
 const date=calendarDate||W.today;
 const period=prefs.calendarPeriod||'month';
 const month=date.slice(0,7)+'-01';
 const year=date.slice(0,4);
 const weekday=(new Date(date+'T00:00:00Z').getUTCDay()+6)%7;
 const monthWeekday=(new Date(month+'T00:00:00Z').getUTCDay()+6)%7;
 const weekStart=addDays(date,-weekday);
 const byDate=new Map();
 for(const task of sortTasks(tasks)){
   if(!task.due_date)continue;
   if(!byDate.has(task.due_date))byDate.set(task.due_date,[]);
   byDate.get(task.due_date).push(task);
 }
 const monthLabel=value=>new Intl.DateTimeFormat('ru',{month:'long',year:'numeric',timeZone:'UTC'}).format(new Date(value+'T00:00:00Z'));
 const titles={day:dateLabel(date),week:dateLabel(weekStart)+' — '+dateLabel(addDays(weekStart,6)),month:monthLabel(month),year};
 const dayCell=(day,adjacent=false)=>`<div class="calendar-day ${day===W.today?'calendar-today':''} ${adjacent?'calendar-adjacent':''}">
   <time datetime="${day}" aria-label="${esc(dateLabel(day))}">${Number(day.slice(-2))}</time>
   ${(byDate.get(day)||[]).map(task=>{
     const completed=task.stage_kind==='done';
     const state=completed?'done':task.overdue?'overdue':'';
     const title=esc(task.title);
     const assignee=esc(person(task.assignee_id));
     const status=completed?'выполнено':task.overdue?'просрочено':'';
     return `<button class="calendar-task ${state?'calendar-task-'+state:''}" data-task="${task.id}" ${status?`aria-label="${title}, ${assignee}, ${status}"`:''}>
       <strong>${completed?'<span class="calendar-task-check" aria-hidden="true">✅</span> ':''}${title}</strong><span>${assignee}</span>
     </button>`;
   }).join('')}
 </div>`;
 const dates=Array.from({length:period==='week'?7:42},(_,index)=>addDays(period==='week'?weekStart:addDays(month,-monthWeekday),index));
 const weekdays=['Пн','Вт','Ср','Чт','Пт','Сб','Вс'];
 const yearMonths=()=>Array.from({length:12},(_,index)=>{
   const prefix=year+'-'+String(index+1).padStart(2,'0');
   const days=[...byDate.keys()].filter(day=>day.startsWith(prefix)).sort();
   return `<section class="calendar-month"><h3>${esc(monthLabel(prefix+'-01'))}</h3>${days.map(day=>dayCell(day)).join('')||'<p class="muted">Нет задач</p>'}</section>`;
 }).join('');
 return `<div class="section-heading"><h2>${esc(titles[period])}</h2><div class="row-actions">
 <select id="calendarPeriod" aria-label="Период календаря">${Object.entries(calendarPeriods).map(([key,label])=>option(key,label,period)).join('')}</select>
 <button data-calendar-step="-1" aria-label="Предыдущий период">←</button>
 <button data-calendar-step="0">Сегодня</button>
 <button data-calendar-step="1" aria-label="Следующий период">→</button></div></div>
 ${period==='day'?dayCell(date):period==='year'?`<div class="calendar-year">${yearMonths()}</div>`:
 `<div class="gantt-scroll" tabindex="0" aria-label="Календарь задач"><div class="task-calendar">
 ${weekdays.map(day=>`<strong>${day}</strong>`).join('')}
 ${dates.map(day=>dayCell(day,period==='month'&&day.slice(0,7)!==month.slice(0,7))).join('')}</div></div>`}`;
}

function renderGantt(tasks){
 const day=86_400_000;
 const origin=Date.parse(W.today+'T00:00:00Z');
 const offset=date=>date?(Date.parse(date+'T00:00:00Z')-origin)/day+7:NaN;
 const span=28;
 const percent=value=>100*Math.min(span,Math.max(0,value))/span;
 const visible=r=>Number.isFinite(r.start)&&Number.isFinite(r.end)?r.start<span&&r.end>=0:r.end>=0&&r.end<span;
 const groups=new Map(W.projects.filter(p=>!p.archived).map(p=>[p.id,{
   name:p.title,start:offset(p.start_date),end:offset(p.end_date),id:p.id,
   scheduled:!['completed','cancelled'].includes(p.status),tasks:[]
 }]));
 const unassigned={name:'Без проекта',tasks:[]};
 for(const t of tasks){
   const row={name:t.title,start:NaN,end:offset(t.due_date),id:t.id};
   if(visible(row))(groups.get(t.project_id)||unassigned).tasks.push(row);
 }
 const rows=[...groups.values(),unassigned].filter(group=>group.tasks.length||(group.scheduled&&visible(group)));
 const weeks=Array.from({length:4},(_,i)=>new Date(origin+(i*7-7)*day).toISOString().slice(0,10));
 const track=row=>{
   if(!visible(row))return '<div class="gantt-track" aria-hidden="true"></div>';
   const duration=Number.isFinite(row.start)&&row.start<=row.end;
   const left=percent(duration?row.start:row.end);
   const width=duration?percent(row.end+1)-left:0;
   const format=value=>dateLabel(new Date(origin+(value-7)*day).toISOString().slice(0,10));
   const dates=(duration?format(row.start)+' – ':'')+format(row.end);
   return `<div class="gantt-track" title="${esc(dates)}"><span class="sr-only">${esc(dates)}</span><span aria-hidden="true" class="gantt-mark ${duration?'gantt-bar':'gantt-dot'}" style="--left:${left}%;--width:${width}%"></span></div>`;
 };
 return `<div class="section-heading"><h2>Диаграмма Ганта</h2><span class="muted">4 недели · сегодня отмечено линией</span></div><p class="muted">Полоса — период проекта. Точка — срок задачи или проекта без даты начала.</p>
 ${rows.length?`<div class="gantt-scroll" tabindex="0" aria-label="Календарь проектов и задач"><div class="gantt-grid"><span>Проект / задача</span><div class="gantt-weeks">${weeks.map(date=>`<span>${esc(dateLabel(date))}</span>`).join('')}</div>${rows.map(r=>{
   const key=String(r.id??'none');
   return `<details class="gantt-group" data-gantt-group="${key}" ${expandedGanttGroups.has(key)?'open':''}>
    <summary><span class="gantt-group-name">${esc(r.name)} <small>· ${r.tasks.length}</small></span>${track(r)}</summary>
    <div class="gantt-group-body">${r.id?`<button class="link-button" data-project="${r.id}">Открыть проект</button><span></span>`:''}
    ${r.tasks.map(task=>`<button class="task-title gantt-title" data-task="${task.id}" title="${esc(task.name)}">${esc(task.name)}</button>${track(task)}`).join('')||'<p class="muted">Нет задач со сроком в этом периоде.</p>'}</div>
   </details>`;
 }).join('')}</div></div>`:'<p class="muted">В этом периоде нет проектов или задач с датами.</p>'}`;
}

function renderTaskCharts(tasks){
 const nextWeek=addDays(W.today,7);
 const buckets=[
   ['Просрочено',tasks.filter(t=>t.overdue).length,'late'],
   ['Ближайшие 7 дней',tasks.filter(t=>!t.overdue&&t.due_date>=W.today&&t.due_date<nextWeek).length,'soon'],
   ['Позже',tasks.filter(t=>!t.overdue&&t.due_date>=nextWeek).length,'later'],
   ['Без срока',tasks.filter(t=>!t.due_date).length,'none']
 ];
 const owners=new Map();
 for(const task of tasks)owners.set(task.assignee_id,(owners.get(task.assignee_id)||0)+1);
 const workload=[...owners].sort((a,b)=>b[1]-a[1]).map(([id,count])=>[id?person(id):'Без исполнителя',count,'owner',id??'none']);
 const chart=(title,values)=>{
   const max=Math.max(1,...values.map(([,count])=>count));
   const bars=values.map(([label,count,state,owner])=>{
     const quickFilter={late:'overdue',none:'undated',soon:'due-soon',later:'due-later',owner:'chart-owner'}[state];
     const content=`<span>${esc(label)}</span><meter class="chart-${state}" min="0" max="${max}" value="${count}" aria-hidden="true"></meter><strong>${count}</strong>`;
     return quickFilter
       ?`<button type="button" class="chart-row chart-drilldown" data-quick="${quickFilter}" data-chart-scope data-chart-owner="${esc(owner??'')}">${content}</button>`
       :`<div class="chart-row">${content}</div>`;
   }).join('');
   return `<section class="section overview-chart"><h2>${title}</h2>${bars||'<p class="muted">Нет активных задач.</p>'}</section>`;
 };
 return `<div class="overview-charts">${chart('Сроки активных задач',buckets)}${chart('Активные задачи по исполнителям',workload)}</div>`;
}

function overviewCharts(){
 const tasks=filterTasks(W,{active:true});
 const calendar=prefs.overviewSchedule==='calendar';
 return `<section class="section overview-gantt"><div class="segmented schedule-switch" role="group" aria-label="Вид расписания">
 <button data-overview-schedule="gantt" aria-pressed="${!calendar}" class="${!calendar?'selected':''}">Диаграмма Ганта</button>
 <button data-overview-schedule="calendar" aria-pressed="${calendar}" class="${calendar?'selected':''}">Календарь задач</button>
 </div>${calendar?taskCalendar(filterTasks(W,{statuses:['kind:active','kind:done']})):renderGantt(tasks)}</section>
 ${renderTaskCharts(tasks)}`;
}

function renderOverview(){const parts=overview(W,prefs.overviewFilters),pending=W.proposals.filter(p=>p.status==='pending'),blocked=filterTasks(W,{active:true,blocked:true}),mine=filterTasks(W,{active:true,assignees:['me']});return `<p class="muted">${dateLabel(W.today)} · Всё, что требует вашего внимания</p><div class="metrics"><button class="metric" data-quick="mine"><strong>${mine.length}</strong><span>Мои задачи</span></button><button class="metric" data-quick="today"><strong>${parts.today.length}</strong><span>Сегодня</span></button><button class="metric alert" data-quick="overdue"><strong>${parts.overdue.length}</strong><span>Просрочены</span></button><button class="metric" data-nav="approvals"><strong>${pending.length}</strong><span>На подтверждение</span></button></div><details class="secondary-filters"><summary>Период и область обзора</summary>${commonOverviewFilters()}</details>${overviewCharts()}<div class="today-grid"><div><section class="section"><div class="section-heading"><h2>В фокусе</h2><button class="link-button" data-quick="today">Все задачи</button></div>${todayTasks([...parts.overdue,...parts.today,...parts.upcoming])}${meId(W)==null?'<p class="muted">Выберите «Кто я» в настройках, чтобы видеть свои задачи.</p>':''}</section><section class="section"><div class="section-heading"><h2>Нужно решение</h2><button class="link-button" data-nav="approvals">На подтверждение</button></div>${pending.length?pending.slice(0,3).map(p=>`<p><button class="task-title" data-review="${p.id}">${esc(p.title)}</button></p>`).join(''):empty('Новых предложений нет. Поручения становятся задачами после подтверждения.')}${blocked.length?`<h3>Блокировки</h3>${todayTasks(blocked)}`:''}</section><section class="section"><div class="section-heading"><h2>Проекты</h2><button class="link-button" data-nav="projects">Все проекты</button></div><div class="project-grid">${W.projects.filter(p=>!p.archived&&!['completed','cancelled'].includes(p.status)).slice(0,3).map(projectCard).join('')||empty('Добавьте первый проект.','new-project','Создать проект')}</div></section></div><div><section class="section"><div class="section-heading"><h2>Совещания</h2><button class="link-button" data-nav="meetings">Все встречи</button></div>${meetingRows(W.meetings.slice(0,4))}</section><section class="section assistant-card"><span class="badge">Ассистент · не подключён</span><h2 style="margin-top:16px">Держать фокус проще</h2><p class="muted">Задачи, блокировки и поручения в контексте вашего дня.</p><button data-action="assistant">Открыть помощника</button><p class="muted">Резюме и задачи Groq — в итогах встречи. Чат, бот и уведомления пока недоступны.</p></section></div></div>`;}
function openAssistant(){$('#assistantButton').click();}
function projectMilestone(p){return p.next_milestone?`${esc(p.next_milestone)}${p.next_milestone_date?' · '+esc(dateLabel(p.next_milestone_date)):''}`:'Не указан';}
function projectCard(p){return `<button class="card project-card" data-project="${p.id}"><h3>${esc(p.title)}</h3><div><span class="badge">${projectStatuses[p.status]}</span>${p.overdue?'<span class="badge danger">Проект просрочен</span>':''}${p.blocker?'<span class="badge warning">Есть препятствие</span>':''}</div><p class="project-goal">${esc(p.goal||p.description||'Цель пока не указана')}</p><p>Владелец: ${esc(person(p.owner_id))}</p><p><strong>Ближайший этап:</strong> ${projectMilestone(p)}</p><p>Плановое завершение: ${esc(dateLabel(p.end_date))}</p>${p.blocker?`<p class="project-blocker">${esc(p.blocker)}</p>`:''}<div class="project-footer"><span>${p.task_counts.active} текущих · ${p.task_counts.overdue} просроченных</span><span>${p.task_counts.done} / ${p.task_counts.total} готово</span></div></button>`;}
function renderProjects(){if(prefs.projectId)return renderProject();const f=prefs.projectFilters,q=(f.q||'').toLocaleLowerCase('ru');const rows=W.projects.filter(p=>Boolean(p.archived)===Boolean(f.archived)&&(!q||[p.title,p.description,p.goal,p.next_milestone,p.blocker,p.materials].filter(Boolean).join(' ').toLocaleLowerCase('ru').includes(q))&&(!f.status||p.status===f.status)&&(!f.owner||String(p.owner_id??'none')===f.owner));return `<div class="filters"><label>Раздел<select id="projectArchiveFilter">${option("active","Рабочие проекты",f.archived?"archived":"active")}${option("archived","Архив",f.archived?"archived":"active")}</select></label><label>Поиск<input id="projectSearch" type="search" placeholder="Название проекта" value="${esc(f.q)}"></label><label>Статус<select id="projectStatus">${option('','Все статусы',f.status)}${Object.entries(projectStatuses).map(([k,v])=>option(k,v,f.status)).join('')}</select></label><label>Владелец<select id="projectOwner">${option('','Все владельцы',f.owner)}${option('none','Не назначен',f.owner)}${W.people.map(p=>option(p.id,p.name,f.owner)).join('')}</select></label></div><div class="filters"><div class="segmented"><button data-project-view="cards" class="${prefs.projectView==='cards'?'selected':''}">Карточки</button><button data-project-view="list" class="${prefs.projectView==='list'?'selected':''}">Список</button></div></div>${!rows.length?f.archived?empty('В архиве нет проектов с такими условиями.'):empty('Нет проектов с такими условиями.','new-project','Создать проект'):prefs.projectView==='cards'?`<div class="project-grid">${rows.map(projectCard).join('')}</div>`:`<section class="section table-wrap"><table class="data-table"><thead><tr><th>Проект</th><th>Владелец</th><th>Статус</th><th>Плановый срок</th><th>Задачи</th></tr></thead><tbody>${rows.map(p=>`<tr><td><button class="task-title" data-project="${p.id}">${esc(p.title)}</button>${p.overdue?'<span class="inline-detail">Проект просрочен</span>':''}</td><td>${esc(person(p.owner_id))}</td><td>${projectStatuses[p.status]}</td><td>${dateLabel(p.end_date)}</td><td>${p.task_counts.active} текущих / ${p.task_counts.overdue} просроченных</td></tr>`).join('')}</tbody></table></section>`}`;}
function renderProject(){const p=W.projects.find(p=>p.id===prefs.projectId);if(!p)return empty('Проект не найден.');const tasks=filterTasks(W,{projects:[String(p.id)]});const meetings=W.meetings.filter(m=>m.project_id===p.id);let content='';if(projectTab==='tasks')content=p.archived?empty('Задачи появятся после восстановления проекта.'):renderTasks(p.id);else if(projectTab==='meetings')content=meetingRows(meetings);else if(projectTab==='decisions'){const decisions=W.decisions.filter(d=>d.project_id===p.id);content='<section class="section"><h2>Как формулировать решения</h2><p>На совещании проговорите, о чём договорились. Например: «Решили использовать лён для костюмов». Если нужно поручить действие, сформулируйте его отдельно: «Лена, закажи лён до пятницы». Предложения ассистента можно проверить во вкладке «На подтверждение».</p></section>'+(decisions.length?decisions.map(d=>`<article class="card"><p>${esc(d.text)}</p>${sourceButton(d.source)}</article>`).join(''):empty('Подтверждённых решений пока нет.'));}else if(projectTab==='settings')content=`<section class="section"><h2>Параметры и этапы проекта</h2><p>Имена, порядок и системные типы этапов изменяются в форме проекта. Удаление занятого этапа требует переноса задач.</p><button data-edit-project="${p.id}">Изменить проект и пайплайн</button></section>`;else content=`<section class="section"><div class="section-heading"><h2>${esc(p.title)}</h2><span class="badge">${projectStatuses[p.status]}</span></div><dl class="project-facts"><div><dt>Дата начала</dt><dd>${dateLabel(p.start_date)}</dd></div><div><dt>Плановый срок</dt><dd>${dateLabel(p.end_date)}</dd></div><div><dt>Владелец</dt><dd>${esc(person(p.owner_id))}</dd></div><div><dt>Команда проекта</dt><dd>${(p.members||[]).map(person).map(esc).join(', ')||'Не выбрана'}</dd></div></dl><div class="metrics project-metrics">${p.archived?'':`<button class="metric" data-project-task-filter="all"><strong>${p.task_counts.total}</strong><span>Все задачи</span></button><button class="metric" data-project-task-filter="active"><strong>${p.task_counts.active}</strong><span>Текущие задачи</span></button><button class="metric alert" data-project-task-filter="overdue"><strong>${p.task_counts.overdue}</strong><span>Просроченные задачи</span></button><button class="metric" data-project-task-filter="done"><strong>${p.task_counts.done}</strong><span>Выполнено из ${p.task_counts.total}</span></button>`}<button class="metric" data-project-tab="meetings"><strong>${meetings.length}</strong><span>Совещания</span></button></div><h3>Материалы</h3><p class="notes-text">${esc(p.materials||'Материалы пока не добавлены.')}</p><h3>Цель</h3><p class="notes-text">${esc(p.goal||'Цель пока не указана.')}</p>${p.description?`<h3>Описание</h3><p class="notes-text">${esc(p.description)}</p>`:''}<h3>Ближайший этап</h3><p>${projectMilestone(p)}</p><h3>Препятствия</h3><p class="notes-text ${p.blocker?'project-blocker':'muted'}">${esc(p.blocker||'Препятствия не указаны.')}</p>${tasks.some(t=>t.active&&t.blocked)?`<h3>Заблокированные задачи</h3>${tasks.filter(t=>t.active&&t.blocked).map(t=>`<p><button class="link-button" data-task="${t.id}">${esc(t.title)}</button><small> · ${esc(t.blocked_reason||'Причина не указана')}</small></p>`).join('')}`:''}${p.overdue?'<div class="callout danger">Просрочен срок самого проекта.</div>':''}</section>${p.archived?'':`<section class="section"><h2>Ближайшие задачи проекта</h2>${smallTasks(sortTasks(tasks.filter(t=>t.active)).slice(0,6))}</section>`}<section class="section"><div class="section-heading"><h2>Последние совещания</h2><button data-project-tab="meetings">Все совещания</button></div>${meetingRows([...meetings].sort((a,b)=>b.created_at.localeCompare(a.created_at)).slice(0,3))}</section>`;return `<button class="link-button" data-nav="projects">← К списку проектов</button><div class="row-actions"><button class="primary" data-action="new-task">Новая задача</button><button data-action="new-meeting">Новое совещание</button>${p.archived?'<span class="badge">В архиве</span>':''}<button data-edit-project="${p.id}">Редактировать карточку</button><button data-archive-project="${p.id}">${p.archived?'Восстановить из архива':'В архив'}</button></div><div class="tabs">${[['overview','Обзор'],['tasks','Задачи'],['meetings','Совещания'],['decisions','Решения'],['settings','Настройки']].map(([key,title])=>`<button data-project-tab="${key}" class="${projectTab===key?'selected':''}">${title}</button>`).join('')}</div>${content}`;}
function fullTaskFilterPanel(context){const f=context?{...prefs.taskFilters,projects:[String(context)]}:prefs.taskFilters;const statuses=new Map();for(const task of filterTasks(W))statuses.set(stageKey(task),`${project(task.project_id)} — ${task.stage_title}`);const multi=(key,label,items)=>`<fieldset><legend>${label}</legend>${items.map(([value,title])=>`<label class="check"><input type="checkbox" data-multi-filter="${key}" value="${esc(value)}" ${(f[key]||[]).includes(String(value))?'checked':''}>${esc(title)}</label>`).join('')}</fieldset>`;return `<div class="filters"><label>Поиск задач<input id="taskSearch" type="search" value="${esc(f.q)}" placeholder="Название или описание"></label>${!context?`<label>Проект<select id="taskProject">${option('','Все проекты',f.projects?.[0])}${option('none','Без проекта',f.projects?.[0])}${W.projects.filter(p=>!p.archived).map(p=>option(p.id,p.title,f.projects?.[0])).join('')}</select></label>`:''}<label>Ответственный<select id="taskAssignee">${option('','Все',f.assignees?.[0])}${option('me','Я',f.assignees?.[0])}${option('none','Не назначен',f.assignees?.[0])}${W.people.map(p=>option(p.id,p.name,f.assignees?.[0])).join('')}</select></label><label>Сортировка<select id="taskSort">${[['due','Срок'],['priority','Приоритет'],['created','Создано'],['updated','Обновлено']].map(([k,v])=>option(k,v,prefs.sort)).join('')}</select></label><label>Группировка<select id="taskGroup">${[['none','Нет'],['project','Проект'],['assignee','Ответственный'],['status','Статус']].map(([k,v])=>option(k,v,prefs.group)).join('')}</select></label></div><div class="row-actions"><div class="segmented"><button data-task-view="list" class="${prefs.taskView==='list'?'selected':''}">Список</button><button data-task-view="board" class="${prefs.taskView==='board'?'selected':''}">Пайплайн</button></div><button data-action="advanced-filters">${prefs.advanced?'Скрыть':'Все фильтры'}</button><button data-action="save-view">Сохранить выборку</button><button data-action="reset-filters">Сбросить</button><button data-action="new-task">＋ Задача</button></div>${prefs.advanced?`<div class="section form-grid" style="margin-top:16px">${context?'<p class="muted">Проект: '+esc(project(context))+'</p>':multi('projects','Проекты',[['none','Без проекта'],...W.projects.filter(p=>!p.archived).map(p=>[String(p.id),p.title])])}${multi('assignees','Ответственные',[['me','Я'],['none','Не назначен'],...W.people.map(p=>[String(p.id),p.name])])}${multi('statuses','Статусы',[['kind:active','Все текущие'],['kind:done','Все завершённые'],['kind:cancelled','Все отменённые'],...statuses])}${multi('priorities','Приоритет',Object.entries(priorities))}${multi('dues','Срок',[['overdue','Просроченные'],['today','Сегодня'],['week','Семь дней'],['due-soon','Ближайшие 7 дней без просрочки'],['due-later','Позже'],['range','Диапазон'],['none','Без срока']])}<div><label>С даты<input id="taskFrom" type="date" value="${esc(f.from)}"></label><label>По дату<input id="taskTo" type="date" value="${esc(f.to)}"></label><label>Источник<select id="taskSource">${option('','Все',f.source)}${option('meeting','Встреча',f.source)}${option('manual','Создана вручную',f.source)}</select></label><label class="check"><input id="taskBlocked" type="checkbox" ${f.blocked?'checked':''}>Только заблокированные</label><label class="check"><input id="taskActive" type="checkbox" ${f.active?'checked':''}>Только текущие</label></div></div>`:''}<div class="chips">${Object.keys(f).filter(k=>Array.isArray(f[k])?f[k].length:!!f[k]).length?`<span class="badge blue">Активные фильтры: ${Object.entries(f).filter(([,v])=>Array.isArray(v)?v.length:!!v).map(([k,v])=>esc(({q:'Поиск',projects:'Проекты',assignees:'Ответственные',statuses:'Статусы',priorities:'Приоритет',dues:'Срок',blocked:'Блокировка',active:'Текущие',source:'Источник',from:'С',to:'По',windowFrom:'Горизонт с',windowTo:'Горизонт по',missing:'Нужен ответственный или срок'})[k]||k)+': '+esc(Array.isArray(v)?v.length+' выбрано':typeof v==='boolean'?'да':v)).join(' · ')}</span>`:'<span class="muted">Все задачи</span>'}</div><div class="chips">${[['mine','Мои текущие'],['overdue','Просроченные'],['today','На сегодня'],['unassigned','Без ответственного'],['undated','Без срока'],['blocked','Заблокированные']].map(([k,v])=>`<button class="chip" data-quick="${k}">${v}</button>`).join('')}${(W.settings.saved_views||[]).map((v,i)=>`<button class="chip" data-saved-view="${i}">★ ${esc(v.name)}</button>`).join('')}</div>`;}
function taskFilterPanel(context){let advanced=fullTaskFilterPanel(context);advanced=advanced.replace(/<label>Поиск задач[\s\S]*?<\/label>/,'').replace(/<button data-action="new-task">[\s\S]*?<\/button>/,'');return `<div class="task-toolbar"><label>Поиск задач<input id="taskSearch" type="search" value="${esc(prefs.taskFilters.q||'')}" placeholder="Название или описание"></label><div class="row-actions"><button data-quick="mine">Мои</button><button data-quick="today">Сегодня</button><button data-quick="overdue">Просрочены</button><div class="segmented"><button data-task-view="list" class="${prefs.taskView==='list'?'selected':''}">Список</button><button data-task-view="board" class="${prefs.taskView==='board'?'selected':''}">Доска</button></div></div></div><details class="secondary-filters" ${prefs.advanced?'open':''}><summary>Фильтры и сохранённые выборки</summary>${advanced}</details>`;}
function renderTasks(context=null){
 const archivedIds=new Set(W.projects.filter(project=>project.archived).map(project=>String(project.id)));
 const filters=prefs.taskFilters;
 const projects=(filters.projects||[]).filter(id=>!archivedIds.has(String(id)));
 const statuses=(filters.statuses||[]).filter(key=>!archivedIds.has(key.split(':',1)[0]));
 if(projects.length!==(filters.projects||[]).length || statuses.length!==(filters.statuses||[]).length){
   prefs.taskFilters={...filters,projects,statuses};
   savePrefs();
 }
 const f={...prefs.taskFilters,...(context?{projects:[String(context)]}:{})};const tasks=sortTasks(filterTasks(W,f),prefs.sort);const selectedCount=tasks.filter(t=>selected.has(t.id)).length;return `${taskFilterPanel(context)}${selectedCount?`<div class="bulk-bar"><strong>Выбрано: ${selectedCount}</strong><button data-bulk="stage">Изменить статус</button><button data-bulk="assignee">Назначить</button><button data-bulk="due">Изменить срок</button><button data-action="clear-selection">Снять выбор</button></div>`:''}<p class="muted">Найдено задач: ${tasks.length}</p>${!tasks.length?empty('Нет задач с такими условиями.','new-task','Создать задачу'):prefs.taskView==='board'?renderBoard(tasks):groupTasks(W,tasks,prefs.group).map(group=>`<section class="section">${group.title?`<h2>${esc(group.title)}<span class="section-count">${group.tasks.length}</span></h2>`:''}${taskTable(group.tasks)}</section>`).join('')}`;}
function renderBoard(tasks){return boardGroups(W,tasks).map(group=>`<section aria-label="Пайплайн ${esc(group.title)}"><h2>${esc(group.title)}</h2><div class="board">${group.stages.map(stage=>{const cards=group.tasks.filter(t=>t.stage_id===stage.id);return `<div class="board-column" data-drop-stage="${esc(stage.id)}" data-drop-project="${group.id}"><h3>${esc(stage.title)} <span>${cards.length}</span></h3>${cards.map(t=>`<article class="kanban-card" draggable="true" data-drag-task="${t.id}"><label class="check"><input type="checkbox" data-select-task="${t.id}" ${selected.has(t.id)?'checked':''} aria-label="Выбрать ${esc(t.title)}"><span class="sr-only">Выбор задачи</span></label><button class="task-title" data-task="${t.id}">${esc(t.title)}</button><p>${esc(person(t.assignee_id))}</p><p>${deadline(t)}</p><span class="badge priority-${t.priority}">${priorities[t.priority]}</span>${t.blocked?'<span class="badge warning">Заблокировано</span>':''}<p>${esc(project(t.project_id))}</p><label>Переместить в<select data-move-task="${t.id}">${group.stages.map(s=>option(s.id,s.title,t.stage_id)).join('')}</select></label></article>`).join('')}${!cards.length?'<p class="muted">Нет задач</p>':''}</div>`;}).join('')}</div></section>`).join('');}
function meetingRows(rows){return rows.length?`<div class="meeting-list">${rows.map(m=>`<button class="card meeting-row" data-meeting="${m.id}"><div><h3>${esc(m.title)}</h3><small>${stamp(m.created_at)} · ${esc(project(m.project_id))}</small></div><div><span class="badge ${m.processing?.status==='failed'?'danger':m.processing?.status==='completed'?'success':'blue'}">${esc(m.processing?statusLabel(m.processing.status):statusLabel(m.status))}</span><small class="inline-detail">${m.recordings.length?'Аудио сохранено':'Без аудиофайла'}</small></div></button>`).join('')}</div>`:empty('Встреч пока нет.','new-meeting','Создать встречу');}
let meetingAssistantOpen;
const expandedMeetingTranscripts = new Set();

function renderMeetings(){if(prefs.meetingId){const m=W.meetings.find(m=>m.id===prefs.meetingId);if(!m)return empty('Встреча не найдена.');return `<button class="link-button" data-nav="meetings">← История встреч</button><div class="meeting-layout"><div class="meeting-main"><div id="meetingProgress" class="meeting-progress" role="status" hidden></div><section class="section meeting-stage-card"><div id="meetingControls"></div></section><div id="meetingRecognitionStatus" hidden></div><section id="meetingLatestSpeech" class="section meeting-latest-speech" aria-label="Последняя реплика" hidden></section><div class="tabs meeting-tabs" role="tablist" aria-label="Результаты совещания">${[['transcript','Протокол'],['summary','Итоги'],['tasks','Задачи'],['audio','Аудио']].map(([key,title])=>`<button role="tab" id="meeting-tab-${key}" data-meeting-tab="${key}" aria-controls="meeting-${key}-pane">${title}</button>`).join('')}</div><section class="section" id="meeting-summary-pane" role="tabpanel" aria-labelledby="meeting-tab-summary"></section><section class="section" id="meeting-transcript-pane" role="tabpanel" aria-labelledby="meeting-tab-transcript"><div class="section-heading"><h2>Протокол</h2><div class="row-actions"><a href="/api/export/${m.id}?format=txt" download>TXT</a><a href="/api/export/${m.id}" download>JSON</a></div></div><div class="filters"><label>Поиск по тексту<input id="transcriptSearch" type="search" placeholder="Найти фразу" value="${esc(transcriptQuery)}"></label><button data-action="previous-match" aria-label="Предыдущее совпадение">↑</button><button data-action="next-match" aria-label="Следующее совпадение">↓</button><span id="matchCount" class="muted"></span><button data-action="follow-transcript" ${!m.recordings.length?'disabled title="Нет аудиозаписи"':''}>К текущему фрагменту</button></div><div id="meetingLive" hidden></div><details id="meetingTranscriptDisclosure" class="meeting-transcript-disclosure" ${expandedMeetingTranscripts.has(m.id)?'open':''}><summary>Расшифровка</summary><div id="meetingTranscript" class="transcript" tabindex="0" aria-label="Текст встречи"></div></details><div id="voiceMatchingControls"></div><div class="row-actions"><button id="transcriptEditMode" data-action="toggle-transcript-edit">Редактировать</button></div></section><section class="section" id="meeting-tasks-pane" role="tabpanel" aria-labelledby="meeting-tab-tasks"><div id="meetingRelated"></div></section><section class="section" id="meeting-audio-pane" role="tabpanel" aria-labelledby="meeting-tab-audio" hidden><div class="compact-audio" id="meetingAudio"></div></section><details class="section meeting-support" id="meetingSupport"><summary>Настройки и источники записи</summary><div id="meetingExtras"></div></details></div><details class="meeting-inspector" ${(meetingAssistantOpen??matchMedia('(min-width:1101px)').matches)?'open':''}><summary><span class="assistant-avatar" aria-hidden="true"></span>Ассистент</summary><aside id="meetingAssistant" aria-label="Поручения встречи"></aside></details></div>`;}
 const f=prefs.meetingFilters||{};const q=(f.q||'').toLowerCase();const rows=W.meetings.filter(m=>(!q||m.title.toLowerCase().includes(q))&&(!f.project||String(m.project_id)===f.project)&&(!f.person||m.participants.includes(Number(f.person)))&&(!f.status||(m.processing?.status||m.status)===f.status)&&(!f.from||m.created_at.slice(0,10)>=f.from)&&(!f.to||m.created_at.slice(0,10)<=f.to));return `<div class="filters"><label>Поиск<input type="search" id="meetingSearch" value="${esc(f.q)}" placeholder="Название встречи"></label><label>Проект<select id="meetingProject">${option('','Все проекты',f.project)}${W.projects.map(p=>option(p.id,p.title,f.project)).join('')}</select></label><label>Участник<select id="meetingPerson">${option('','Все участники',f.person)}${W.people.map(p=>option(p.id,p.name,f.person)).join('')}</select></label><label>Состояние<select id="meetingStatus">${option('','Любое',f.status)}${['created','recording','pending','running','completed','failed'].map(s=>option(s,statusLabel(s),f.status)).join('')}</select></label><label>С даты<input type="date" id="meetingFrom" value="${esc(f.from)}"></label><label>По дату<input type="date" id="meetingTo" value="${esc(f.to)}"></label></div>${meetingRows(rows)}`;}
async function loadMeeting(id,quiet=false){try{const data=await api.meeting(id);if(prefs.section!=='meetings'||prefs.meetingId!==id)return;meetingData=data;if(!$('#meetingControls'))return;if(quiet){renderLiveTranscript();renderVoiceMatchingControls();renderMeetingControls();bindMeetingUpload();const oldRun=$('#meetingTranscript')?.dataset.run;const voiceKey=JSON.stringify(data.transcript?.voice_matches||[]);if((oldRun!==String(data.transcript?.model_run_id||'')||$('#meetingTranscript')?.dataset.stale!==String(!!data.transcript?.needs_update)||$('#meetingTranscript')?.dataset.voiceKey!==voiceKey)&&!$('#modal').open)renderTranscript();if($('#meetingAudio')?.dataset.key!==JSON.stringify(data.audio_timeline||data.recordings.map(r=>r.id)))renderMeetingAudio();renderMeetingRelated();applyMeetingTab();}else renderMeetingSections();}catch(e){if(!quiet)error(e.message);}}
function renderMeetingSections(){renderLiveTranscript();renderVoiceMatchingControls();renderMeetingControls();renderMeetingAudio();renderTranscript();renderMeetingRelated();applyMeetingTab();bindMeetingUpload();}
const recognitionStages = {
 preparing:'Подготовка аудио',
 transcribing:'Распознавание речи',
 transcribing_and_separating:'Распознавание речи и разделение голосов',
 separating:'Разделение голосов',
 saving:'Сохранение протокола'
};
function recognitionElapsed(job) {
 if(job?.started_at == null)return '';
 const end=job.status==='running'?Date.now()/1000:job.finished_at;
 return end==null?'':time(Math.max(0,end-job.started_at)*1000);
}
function renderMeetingRecognitionStatus(){
 const box=$('#meetingRecognitionStatus');
 if(!box||!meetingData)return;
 const meeting=W.meetings.find(m=>m.id===prefs.meetingId);
 const job=meeting?.processing;
 const inspector=document.querySelector('.meeting-inspector');
 if(inspector&&!inspector.ontoggle)inspector.ontoggle=()=>{meetingAssistantOpen=inspector.open;};
 const progress=$('#meetingProgress');
 const capture=H.recording.active;
 const analysis=meetingData.analysis;
 const stage=capture?.meeting_id===prefs.meetingId
   ? ({recording:'Идёт запись',paused:'Запись на паузе',stopping:'Сохраняем аудио'}[capture.state]||'Подготовка записи')
   : ['pending','running'].includes(job?.status)?(job.status==='running'?(recognitionStages[job.stage]||'Обработка аудио'):'Распознавание в очереди')
   : analysis?.state==='running'?'Groq анализирует протокол'
   : analysis?.state==='failed'?'Ошибка анализа Groq · подробности в итогах'
   : job?.status==='failed'?(job.error==='Распознавание прервано пользователем'?'Распознавание прервано':'Ошибка распознавания')
   : meetingData.transcript&&!meetingData.transcript.needs_update?'Протокол готов'
   : meetingData.recordings.length?'Аудио сохранено':'';
 if(progress){
   progress.hidden=!stage;
   if(progress.dataset.stage!==stage){
     progress.dataset.stage=stage;
     progress.replaceChildren(document.createTextNode(stage));
     const clock=document.createElement('span');
     clock.className='recognition-timer';
     clock.setAttribute('role','timer');
     progress.append(clock);
   }
   const timer=progress.querySelector('.recognition-timer');
   const elapsed=capture?.meeting_id===prefs.meetingId?'':recognitionElapsed(job);
   if(timer&&timer.textContent!==elapsed)timer.textContent=elapsed;
   progress.classList.toggle('is-capturing',capture?.meeting_id===prefs.meetingId&&capture.state==='recording');
 }
 const active=H.recording.active;
 const stale=meetingData.transcript?.needs_update;
 const needsText=meetingData.recordings.length>0&&(!meetingData.transcript||stale);
 const pending=['pending','running'].includes(job?.status);
 box.hidden=prefs.demo||(!needsText&&!pending);
 if(box.hidden)return;
 const waiting=H.final_waiting===prefs.meetingId;
 const recording=active?.meeting_id===prefs.meetingId;
 const status=recording?'Текст новой записи появится после остановки и распознавания.':waiting||job?.status==='pending'?'Запись сохранена. Распознавание в очереди.':job?.status==='running'?(recognitionStages[job.stage]||'Обработка аудио'):job?.status==='failed'?'Распознавание завершилось с ошибкой. Аудио сохранено.':stale?'Продолжение сохранено. Обновите текст, чтобы включить новую запись.':'Аудио сохранено. Запустите распознавание, чтобы получить текст.';
 const canStart=needsText&&!active&&!waiting&&!pending&&!H.speech.running&&H.speech.configured;
 const failure=job?.status==='failed'?job.error:H.recording.last?.meeting_id===prefs.meetingId?H.auto_process_error:null;
 const key=JSON.stringify([status,canStart,failure]);
 if(box.dataset.key===key)return;
 box.dataset.key=key;
 box.innerHTML=`<div class="callout" role="status"><p>${esc(status)}</p>${failure?`<p>${esc(failure)}</p>`:''}${canStart?'<button data-action="process-meeting">Обновить распознавание</button>':''}</div>`;
}
function renderLiveTranscript(){
 renderMeetingRecognitionStatus();
 const box=$('#meetingLive');if(!box||!meetingData)return;const live=meetingData.live;const latest=$('#meetingLatestSpeech');
 if(latest){
  const segment=(live?.chunks||[]).filter(chunk=>chunk.state==='completed').flatMap(chunk=>chunk.segments).at(-1);
  const recording=H.recording.active?.meeting_id===prefs.meetingId;
  latest.hidden=!recording||!segment?.text;
  if(!latest.hidden&&latest.dataset.text!==segment.text){
   latest.dataset.text=segment.text;
   latest.innerHTML=`<small>Последняя реплика · предварительно</small><p>${esc(segment.text)}</p>`;
  }
 }
 if(!live){
  const recording=H.recording.active?.meeting_id===prefs.meetingId;
  box.hidden=!recording;
  box.dataset.key='';
  if(recording)box.innerHTML='<p class="muted">Предварительный протокол появляется при записи в режиме Live.</p>';
  return;
 }box.hidden=false;
 const key=JSON.stringify([live,meetingData.transcript?.model_run_id]);if(box.dataset.key===key)return;box.dataset.key=key;
 const chunks=live.chunks||[],segments=chunks.filter(c=>c.state==='completed').flatMap(c=>c.segments.map(s=>({...s,chunk_id:c.id})));
 const waiting=chunks.filter(c=>['pending','running'].includes(c.state)).length,failed=chunks.find(c=>c.error),finished=live.state!=='active';
 box.innerHTML=`<details ${meetingData.transcript&&!H.recording.active?'':'open'}><summary>Предварительный протокол · ${segments.length} фрагментов</summary>
 <p class="muted">Текст и метки голосов появляются по мере обработки. Ручные исправления доступны в итоговом протоколе.</p>
 <p role="status">${esc(live.reason||(finished?'Live завершён. Сохранённое аудио доступно для полной обработки.':waiting?'Распознаём сохранённые фрагменты · в очереди: '+waiting:'Ожидаем следующий сохранённый фрагмент записи.'))}</p>
 ${failed?`<p class="callout warning">${esc(failed.error)}</p>`:''}
 ${(live.state==='active'||chunks.some(c=>c.state==='running'))&&!H.recording.active&&!H.live?.running?'<p class="callout warning">Live был прерван. Убедитесь, что прежние процессы завершены, и восстановите очередь.</p>':''}
 ${!H.recording.active&&!H.live?.running&&!H.speech.running&&(['active','interrupted'].includes(live.state)||chunks.some(c=>c.state==='running'))?'<button data-action="recover-live">Восстановить прерванную Live-очередь</button>':''}
 <div class="transcript" tabindex="0" aria-label="Предварительный текст встречи">${segments.length?segments.map(s=>`<article class="segment"><div class="segment-header"><span>${time(s.start_ms)} — ${time(s.end_ms)}</span><span class="badge">${/^speaker_\d+$/.test(s.speaker_id)?esc("Голос "+(Number(s.speaker_id.slice(8))+1)):"Предварительно"}</span></div><p>${esc(s.text)}</p></article>`).join(''):empty('Текст появится после сохранения и распознавания первых секунд аудио.')}</div></details>`;
}
function renderMeetingControls(){const box=$('#meetingControls');if(!box||!meetingData)return;const m=W.meetings.find(m=>m.id===prefs.meetingId);if(!m)return;const active=H.recording.active?.meeting_id===m.id?H.recording.active:null;const job=m.processing;const stale=m.status==='recording'&&!active;const saved=meetingData.recordings.length>0;const state=active?.state||(m.status==='failed'?'failed':job?.status||m.status);const key=JSON.stringify([state,saved,H.speech.running,H.recording.available,H.speech.configured,H.auto_process_error,meetingData.live?.state,H.voice?.running,m.title,m.project_id,m.participants,meetingData.transcript?.model_run_id,meetingData.transcript?.segments?.map(s=>[s.id,s.person_id,s.speaker_id])]);if(box.dataset.key===key)return;box.dataset.key=key;box.classList.toggle('is-recording',!!active);box.innerHTML=participantCircle(m,active)+`<div class="meeting-hero"><div><span class="badge ${state==='failed'?'danger':'blue'}">${esc(statusLabel(state))}</span><h2 style="margin-top:12px">${esc(m.title)}</h2><p class="muted">${esc(project(m.project_id))} · ${stamp(m.created_at)}</p></div><div class="row-actions"><button data-action="edit-meeting">Изменить сведения</button>${active?`<span class="record-clock" id="liveClock">${time(active.elapsed_ms)}</span>`:''}</div></div><div class="steps">${[['Подготовка',true],['Запись',saved||!!active],['Распознавание',job?.status==='running'||job?.status==='completed'],['Готовый текст',!!meetingData.transcript]].map(([title,done],i)=>`<span class="step ${done?'complete':''}"><span class="step-number">${done?'✓':i+1}</span>${title}</span>`).join('')}</div>${prefs.demo?'<div class="callout warning">Демонстрационная встреча. Ни микрофон, ни реальные модели здесь не запускаются.</div>':active?`<div class="callout">${active.state==='paused'?'Запись на паузе.':esc(active.source||'Микрофон')+' · запись продолжается независимо от открытого раздела.'} ${meetingData.live?.state==='active'?'Предварительный текст появляется ниже по мере обработки сохранённых фрагментов.':'Полное распознавание выполняется после завершения.'} Сохранено до <span id="meetingSaved">${timePrecise(active.saved_ms)}</span>.${!active.can_pause?' Пауза требует обновления адаптера микрофона.':''}</div><div class="row-actions">${['recording','paused'].includes(active.state)?`<button data-record="${active.state==='paused'?'resume':'pause'}" data-id="${m.id}" ${active.can_pause?'':'disabled title="Обновите адаптер микрофона для паузы"'}>${active.state==='paused'?'Продолжить запись':'Пауза'}</button>`:''}<button class="danger" data-record="stop" data-id="${m.id}" ${active.state==='stopping'?'disabled':''}>Завершить и сохранить</button></div>`:stale?`<div class="callout warning">Предыдущая запись прервана. Сохранённые WAV можно восстановить. Сначала убедитесь, что прежний процесс микрофона остановлен.</div><button data-action="recover-meeting">Восстановить сохранённые фрагменты</button>`:`${!H.recording.available?'<div class="callout warning">Микрофон пока недоступен: адаптер macOS не собран. Можно импортировать готовую запись. Инструкция находится в настройках.</div>':''}${!H.speech.configured?'<div class="callout warning">Модель распознавания не настроена. Можно начать только запись — аудио сохранится независимо от модели.</div>':''}${state==='failed'?`<div class="callout danger">${saved?(job?.status==='failed'?'Аудио сохранено. Не удалось выполнить обработку; запись доступна ниже.':'Часть записи сохранена и доступна ниже. Ошибка не удаляет завершённые фрагменты.'):'Не удалось завершить запись или обработку.'} ${m.status==='failed'?' Источник: микрофон macOS по умолчанию. Сохранено до '+timePrecise(H.recording.last?.meeting_id===m.id?H.recording.last.saved_ms:(mediaSources().at(-1)?.end||0))+'. ':''}${esc((m.status==='failed'&&H.recording.last?.meeting_id===m.id?H.recording.last.error:'')||job?.error||'')}</div>`:''}<div class="row-actions">${m.status==='failed'?'<button data-action="recover-meeting">Проверить сохранённые фрагменты</button>':''}${(['created','failed'].includes(m.status)||m.status==='completed')?`<button class="primary" data-record="${saved?'continue':'start'}" data-id="${m.id}" ${!H.recording.available||!!H.recording.active||H.speech.running||H.voice?.running?'disabled':''}>${saved?'Продолжить встречу':H.speech.configured?'Начать запись':'Начать только запись'}</button>`:''}<label class="check">Импортировать аудио<input type="file" id="audioImport" accept=".wav,.mp3,.m4a,.aac,.flac" ${!!H.recording.active?'disabled':''}></label>${saved?`<button class="${!meetingData.transcript?'primary':''}" data-action="process-meeting" ${!!H.recording.active||H.speech.running||['pending','running'].includes(job?.status)||!H.speech.configured?'disabled':''}>${meetingData.transcript?'Повторить обработку':'Распознать запись'}</button>`:''}${job?.status==='running'&&H.speech.running?'<button class="danger" data-action="cancel-speech">Прервать распознавание</button>':''}</div><p class="muted">${job?.status==='running'?'Распознаём аудио в фоне. Можно перейти в другой раздел.':job?.status==='pending'?'Задание ожидает запуска.':W.settings.auto_process?'После остановки запись обрабатывается автоматически, если модели настроены.':'Автообработка отключена: распознавание запускается кнопкой.'}</p>`}${H.auto_process_error&&!prefs.demo&&H.recording.last?.meeting_id===m.id?`<p class="callout warning">${esc(H.auto_process_error)}</p>`:''}${!prefs.demo?`<details style="margin-top:16px"><summary>Источники и режим записи</summary><div class="form-grid" style="margin-top:12px"><label>Микрофон<select aria-label="Микрофон" id="meetingMicrophone" ${active?'disabled':''}>${microphoneOptions()}</select></label><label>Режим<select aria-label="Режим обработки" id="meetingProcessingMode" ${active?'disabled':''}>${option('post','После встречи',meetingData.live?'live':H.speech.settings?.processing_mode||'post')}${option('live','Во время встречи: предварительный текст',meetingData.live?'live':H.speech.settings?.processing_mode)}</select></label><label class="check"><input type="checkbox" disabled>Системный звук — адаптер ещё не подключён</label><label>Лимит сессии, секунд<input id="recordLimit" type="number" min="5" max="7200" value="60" ${active?'disabled':''}></label></div><p class="muted">Пауза входит в общий лимит сессии. Проверить уровень можно после начала короткой записи; уровень показывается в глобальной полосе. Микрофон выбирается перед началом записи. Сохранить постоянный выбор и проверить уровень можно в настройках.</p></details>`:''}`;organizeMeetingExtras(box,active);}
function styleRecordIcon(button){
 const action=button.dataset.record||(button.textContent==='Пауза'?'pause':button.textContent==='Остановить'?'stop':'start');
 const label=button.textContent.trim();
 const shapes={start:'<circle cx="12" cy="12" r="7"/>',pause:'<path d="M6 5h4v14H6zm8 0h4v14h-4z"/>',stop:'<rect x="5" y="5" width="14" height="14" rx="2"/>',resume:'<path d="M7 4l13 8-13 8z"/>',continue:'<path d="M7 4l13 8-13 8z"/>'};
 button.classList.add('record-icon','record-icon-'+action);
 button.setAttribute('aria-label',label);button.title=label;
 button.innerHTML=`<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor" aria-hidden="true">${shapes[action]}</svg>`;
}
function organizeMeetingExtras(box,active){const controls=box.querySelector('#circleRecordControls');if(controls){for(const button of [...box.querySelectorAll('[data-record]')]){const parent=button.parentElement;controls.append(button);if(button.dataset.record==='stop')button.textContent='Остановить';if(button.dataset.record==='start')button.textContent='Начать запись';if(parent.classList.contains('row-actions')&&!parent.children.length)parent.remove();}if(!controls.querySelector('[data-record="start"],[data-record="continue"],[data-record="resume"]')&&!active){controls.insertAdjacentHTML('afterbegin','<button class="primary" disabled>Начать запись</button>');}if(!active)controls.insertAdjacentHTML('beforeend','<button disabled>Пауза</button><button disabled>Остановить</button>');for(const button of controls.querySelectorAll('button'))styleRecordIcon(button);}const extras=$('#meetingExtras');
 if(extras)extras.replaceChildren(...[...box.children].filter(node=>!node.classList.contains('recording-stage')));
 renderMeetingCircleStatus();
}
function mediaSources(){if(!meetingData)return [];if(meetingData.audio_timeline){const recordings=new Map(meetingData.recordings.map(r=>[r.id,r]));return meetingData.audio_timeline.map(s=>({recording:recordings.get(s.recording_id),start:s.start_ms,end:s.end_ms})).filter(s=>s.recording);}const recordings=new Map(meetingData.recordings.map(r=>[r.id,r]));const sources=[];let cursor=0;for(const f of meetingData.fragments||[]){const recording=recordings.get(f.recording_id);if(recording){const duration=f.frames*1000/f.sample_rate;sources.push({recording,start:cursor,end:cursor+duration});cursor+=duration;}}for(const recording of meetingData.recordings){if(!(meetingData.fragments||[]).some(f=>f.recording_id===recording.id)){const duration=recording.frames*1000/recording.sample_rate;sources.push({recording,start:cursor,end:cursor+duration});cursor+=duration;}}return sources;}
function renderMeetingAudio(){const root=$('#meetingAudio');if(!root||!meetingData)return;root.dataset.key=JSON.stringify(meetingData.audio_timeline||meetingData.recordings.map(r=>r.id));const sources=mediaSources();root.innerHTML=`<h2>Аудиозапись</h2>${!sources.length?empty(prefs.demo?'В демо доступен текст; реального аудиофайла нет.':'Аудио появится после первого сохранённого фрагмента или импорта.'):`<div class="audio-panel"><audio id="player" controls preload="metadata" aria-label="Прослушивание сохранённой записи"></audio><label>Сохранённые фрагменты<select id="audioTrack">${sources.map((s,i)=>option(i,`${time(s.start)} — ${time(s.end)} · фрагмент ${i+1}`,0)).join('')}</select></label><small>Фрагменты воспроизводятся последовательно. Исходные WAV доступны даже при ошибке распознавания.</small></div>`}`;if(sources.length){const player=$('#player');player.src='/api/audio/'+sources[0].recording.id;$('#audioTrack').onchange=()=>{const index=Number($('#audioTrack').value);player.src='/api/audio/'+sources[index].recording.id;player.load();};player.onended=()=>{const next=Number($('#audioTrack').value)+1;if(next<sources.length){$('#audioTrack').value=next;player.src='/api/audio/'+sources[next].recording.id;player.play().catch(e=>error(e.message));}};player.onplay=player.onpause=player.onseeked=()=>renderMeetingCircleStatus();player.ontimeupdate=()=>{renderMeetingCircleStatus();if(!autoFollow||meetingTab!=='transcript')return;const global=sources[Number($('#audioTrack').value)].start+player.currentTime*1000;const segment=[...document.querySelectorAll('.segment[data-start]')].find(s=>Number(s.dataset.start)<=global&&Number(s.dataset.end)>global);if(segment&&!segment.classList.contains('current')){document.querySelectorAll('.segment.current').forEach(s=>s.classList.remove('current'));segment.classList.add('current');segment.scrollIntoView({block:'nearest',behavior:'auto'});}};}}
function renderVoiceSuggestion(s,index){
 const suggestion=s.voice_suggestion;if(!suggestion)return '';
 if(suggestion.status!=='candidate')return `<p class="muted">Имя по голосу не определено: ${esc(suggestion.reason)}</p>`;
 return `<div class="callout"><p>Подсказка по голосовому профилю: <strong>${esc(suggestion.person_name)}</strong> · сходство ${Number(suggestion.similarity).toFixed(3)}. Требуется подтверждение.</p><div class="row-actions"><button data-confirm-voice="${index}">Подтвердить имя</button><button data-reject-voice="${index}">Оставить неизвестным</button></div></div>`;
}
function renderVoiceClusters(t){
 const ids=[...new Set((t.speaker_turns||[]).map(s=>s.speaker_id))];if(!ids.length)return '';
 const assignments=new Map((t.speaker_assignments||[]).map(a=>[a.speaker_id,a]));
 return `<details><summary>Голоса встречи: ${ids.length}</summary>${ids.map(id=>{const manual=assignments.get(id),match=(t.voice_matches||[]).find(v=>v.speaker_id===id);return `<article class="card" style="margin-top:12px"><strong>${esc(id)}</strong><p>${manual?esc(manual.person_name||'Неизвестный')+' · вручную':match?.status==='candidate'?'Подсказка: '+esc(match.person_name)+' · сходство '+Number(match.similarity).toFixed(3):esc(match?.reason||'Имя ещё не определено')}</p><div class="row-actions"><button data-assign-voice-cluster="${esc(id)}">Назначить имя</button><button data-enroll-voice-cluster="${esc(id)}" ${!H.voice?.configured||H.recording.active?'disabled':''}>Создать профиль голоса</button>${!manual&&match?.status==='candidate'?`<button data-confirm-voice-cluster="${esc(id)}">Подтвердить подсказку</button>`:''}</div></article>`;}).join('')}</details>`;
}
function assignVoiceCluster(speaker){const t=meetingData.transcript,manual=(t.speaker_assignments||[]).find(a=>a.speaker_id===speaker);showDialog('Имя голоса встречи',`<p>Назначение для ${esc(speaker)} относится только к версии ${t.model_run_id}.</p><label>Участник<select name="person_id">${personOptions(manual?.person_id)}</select></label>`,async form=>{await api.request('speaker/assign',{model_run_id:t.model_run_id,speaker_id:speaker,person_id:form.elements.person_id.value?Number(form.elements.person_id.value):null});await loadMeeting(prefs.meetingId);flash('Имя голоса сохранено вручную');});}
function renderVoiceMatchingControls(){
 const box=$('#voiceMatchingControls');if(!box||!meetingData)return;const t=meetingData.transcript;
 if(!t||prefs.demo){box.innerHTML='';return;}
 const jobs=(H.voice_data?.match_jobs||[]).filter(j=>j.model_run_id===t.model_run_id),job=jobs[0],hasSpeakers=t.speaker_turns?.length>0,hasProfiles=(H.voice_data?.profiles||[]).length>0;
 box.innerHTML=`<div class="row-actions"><button data-action="match-voices" ${!H.voice?.configured||!hasSpeakers||!hasProfiles||H.recording.active||H.speech.running||['pending','running'].includes(job?.state)?'disabled':''}>Сопоставить голоса с профилями</button>${job?.state==='failed'?`<button data-retry-voice-match="${job.id}">Повторить сопоставление</button>`:''}${(H.voice_data?.match_jobs||[]).some(j=>j.state==='running')&&!H.voice?.running?'<button data-action="recover-voice-matching">Восстановить очередь голосов</button>':''}</div><p class="muted">${!hasProfiles?'Добавьте голосовые образцы участников для получения подсказок имён.':!hasSpeakers?'Для сопоставления нужно разделение говорящих.':job?.state==='pending'?'Сопоставление ожидает свободного обработчика.':job?.state==='running'?'Сравниваем голоса с локальными профилями.':job?.state==='completed'?'Сопоставление завершено. Подсказки показаны рядом с репликами.':'Имена по голосу предлагаются с порогом сходства; ручные назначения сохраняют приоритет.'}</p>${job?.error?`<p class="callout warning">${esc(job.error)}</p>`:''}${renderVoiceClusters(t)}`;
}
async function enrollSpeaker(index){const s=meetingData.transcript.segments[index];return enrollVoiceCluster(s.speaker_id,s.person_id);}
async function enrollVoiceCluster(speaker,personId=null){
 const t=meetingData.transcript;if(!speaker)throw Error('Выберите один голос встречи');
 const plan=await api.request('voice/source',{model_run_id:t.model_run_id,speaker_id:speaker});
 showDialog('Голосовой профиль из встречи',`<p>Голос ${esc(speaker)} · ${(plan.duration_ms/1000).toFixed(1)} с речи. Участки пересечения голосов исключены.</p><p class="muted">Прослушайте выбранные участки перед подтверждением. Образец будет собран только из этой версии встречи и сохранён локально.</p><div class="row-actions">${plan.intervals.map(r=>`<button type="button" data-seek="${r.start_ms}">▶ ${time(r.start_ms)} — ${time(r.end_ms)}</button>`).join('')}</div><label>Участник<select name="person_id" required>${personOptions(personId)}</select></label><label class="check"><input name="consent" type="checkbox" required>Участник согласен на создание локального голосового профиля из выбранных фрагментов встречи.</label><label class="check"><input name="single_speaker" type="checkbox" required>Я прослушал выбранные фрагменты: в них говорит только этот участник.</label>`,async form=>{
   await api.request('voice/from-meeting',{person_id:Number(form.elements.person_id.value),model_run_id:t.model_run_id,speaker_id:speaker,consent:form.elements.consent.checked,single_speaker:form.elements.single_speaker.checked});await refresh(false);flash('Образец из встречи добавлен в очередь регистрации');
 });
}
function confirmVoice(index){const s=meetingData.transcript.segments[index];confirmVoiceCandidate(s.voice_suggestion,s.text);}
function confirmVoiceCandidate(v,quote=''){if(!v||v.status!=='candidate')return;const t=meetingData.transcript;
 showDialog('Подтвердить имя говорящего',`<blockquote class="quote">${esc(quote)}</blockquote><p>Подсказка: <strong>${esc(v.person_name)}</strong>, сходство ${Number(v.similarity).toFixed(3)}. Это мера сходства, не вероятность личности.</p><p>Имя будет назначено всем репликам голоса ${esc(v.speaker_id)} только в этой версии встречи. Его можно исправить позднее.</p><label>Участник<select name="person_id" required>${personOptions(v.person_id)}</select></label>`,async form=>{await api.request('speaker/assign',{model_run_id:t.model_run_id,speaker_id:v.speaker_id,person_id:Number(form.elements.person_id.value)});await loadMeeting(prefs.meetingId);flash('Имя подтверждено вручную');});
}
function transcriptFlow(segments){
 const query=transcriptQuery.trim().toLocaleLowerCase('ru');
 let previousSpeaker;
 return '<div class="transcript-flow">'+transcriptParagraphs(segments).map(p=>{
  const first=p.segments[0],name=first.person_name||(first.speaker_id?'Голос '+first.speaker_id:(p.speaker==='multiple'?'Несколько говорящих':null));
  const heading=name&&p.speaker!==previousSpeaker?`<strong class="flow-speaker" style="--speaker:${first.person_id?participantColor(first.person_id):'var(--muted)'}">${esc(name)}</strong>`:'';
  previousSpeaker=p.speaker;
  return `<p>${heading}${p.segments.map(s=>`<span class="segment flow-segment ${query&&s.text.toLocaleLowerCase('ru').includes(query)?'match':''}" id="segment-${s.id}" data-start="${s.start_ms}" data-end="${s.end_ms}">${esc(s.text.trim())}</span>`).join(' ')}</p>`;
 }).join('')+'</div>';
}
function renderTranscript(){const root=$('#meetingTranscript');if(!root||!meetingData)return;const t=meetingData.transcript;root.dataset.run=String(t?.model_run_id||'');root.dataset.stale=String(!!t?.needs_update);root.dataset.voiceKey=JSON.stringify(t?.voice_matches||[]);const disclosure=$('#meetingTranscriptDisclosure');const summary=disclosure?.querySelector('summary');if(summary)summary.textContent=t?.segments?.length?`Расшифровка · ${t.segments.length} фрагм.`:'Расшифровка';const edit=$('#transcriptEditMode');if(edit){edit.disabled=!t?.segments?.length;edit.textContent=editTranscriptMode?'К чтению':'Редактировать';edit.setAttribute('aria-pressed',String(editTranscriptMode));}if(disclosure&&!disclosure.open){root.replaceChildren();$('#matchCount').textContent='';return;}if(!t){$('#matchCount').textContent='';root.innerHTML=empty('Транскрипт ещё не получен. Запишите или импортируйте аудио, затем запустите распознавание.');return;}root.innerHTML=`<p class="muted">${t.parameters?.demonstration?'Демонстрационный транскрипт':'Итоговый транскрипт'} · Версия ${t.model_run_id}. Изменения говорящих относятся к этой версии.</p>${t.segments.length?(!editTranscriptMode?transcriptFlow(t.segments):t.segments.map((s,i)=>{const matching=transcriptQuery&&s.text.toLowerCase().includes(transcriptQuery.toLowerCase());return `<article class="segment ${matching?'match':''}" id="segment-${s.id}" style="--speaker:${s.person_id?participantColor(s.person_id):'var(--border)'}" data-start="${s.start_ms}" data-end="${s.end_ms}"><div class="segment-header"><button class="link-button" data-seek="${s.start_ms}" ${!meetingData.recordings.length?'disabled title="Нет аудиофайла"':''}>${time(s.start_ms)} — ${time(s.end_ms)}</button><span>${esc(s.person_name||s.speaker_id||(s.speaker_status==='multiple'?'Несколько говорящих':'Говорящий не определён'))}${String(s.assignment_source||'').startsWith('manual_')?' · вручную':''}</span></div><p>${esc(s.text)}</p>${renderVoiceSuggestion(s,i)}${s.manually_edited?'<small>Текст исправлен вручную; оригинал сохранён.</small>':''}<div class="row-actions"><button data-edit-segment="${i}">Исправить текст</button><button data-assign-segment="${i}">Назначить говорящего</button><button data-propose-segment="${i}">Предложить поручение</button>${s.speaker_id&&!prefs.demo?`<button data-enroll-speaker="${i}" ${!H.voice?.configured||H.recording.active?'disabled':''}>Создать профиль голоса</button>`:''}</div></article>`;}).join('')):empty('Речевые сегменты не найдены.')}`;root.onwheel=()=>{autoFollow=false;};root.ontouchmove=()=>{autoFollow=false;};root.onkeydown=e=>{if(['ArrowUp','ArrowDown','PageUp','PageDown'].includes(e.key))autoFollow=false;};$('#matchCount').textContent=transcriptQuery?`Совпадений: ${root.querySelectorAll('.match').length}`:'';}
function bindMeetingUpload(){const upload=$('#audioImport');if(upload)upload.onchange=async()=>{const file=upload.files[0];if(!file)return;upload.disabled=true;flash('Импортируем аудио…');try{await perform(()=>api.importAudio(prefs.meetingId,file),'Аудио сохранено',false);await loadMeeting(prefs.meetingId);renderAll();}catch{upload.disabled=false;}};}
function renderMeetingAssistant(){
 const panel=$('#meetingAssistant');
 if(!panel)return;
 const pending=W.proposals.filter(p=>p.status==='pending'&&p.source?.meeting_id===prefs.meetingId);
 const proposals=pending.filter(p=>p.kind==='create_task');
 const confirmed=filterTasks(W).filter(t=>(t.sources||[]).some(s=>s.meeting_id===prefs.meetingId));
 panel.innerHTML=`<div class="assistant-tools"><button type="button" data-assistant-search>Поиск задач и проектов</button></div>
 ${proposals.map(proposal=>`<article class="meeting-suggestion"><small>Предложение задачи</small><h3>${esc(proposal.title)}</h3>
 ${proposal.assignee_id||proposal.due_date?`<p class="muted">${proposal.assignee_id?esc(person(proposal.assignee_id)):''}${proposal.assignee_id&&proposal.due_date?' · ':''}${proposal.due_date?deadline(proposal):''}</p>`:''}
 <div class="row-actions"><button class="primary" data-review="${proposal.id}">Проверить</button></div></article>`).join('')}
 ${confirmed.map(task=>`<article class="meeting-suggestion"><small>Подтверждено</small><h3><button class="task-title" data-task="${task.id}">${esc(task.title)}</button></h3><p class="muted">${esc(person(task.assignee_id))} · ${deadline(task)}</p></article>`).join('')}
 ${proposals.length||confirmed.length?'':'<p class="muted">Задачи появятся здесь после анализа встречи.</p>'}`;
}
function renderMeetingRelated(){renderMeetingAssistant();const root=$('#meetingRelated');if(!root)return;const tasks=filterTasks(W).filter(t=>(t.sources||[]).some(s=>s.meeting_id===prefs.meetingId)),pending=W.proposals.filter(p=>p.status==='pending'&&p.source?.meeting_id===prefs.meetingId),decisions=W.decisions.filter(d=>d.meeting_id===prefs.meetingId);root.innerHTML=`<h2>Подтверждённые поручения</h2>${tasks.length?tasks.map(t=>`<article class="card"><button class="task-title" data-task="${t.id}">${esc(t.title)}</button><p class="muted">${esc(person(t.assignee_id))} · ${deadline(t)}</p>${(t.sources||[]).filter(s=>s.meeting_id===prefs.meetingId).map(sourceButton).join('')}</article>`).join(''):empty('Подтверждённых поручений пока нет.')}<h2 style="margin-top:24px">На подтверждение</h2>${pending.length?pending.map(p=>`<article class="card proposal"><h3>${esc(p.title)}</h3>${proposalClarification(p)}${p.kind==='create_task'&&p.due_date?`<p class="muted">Срок ${deadline(p)}</p>`: ''}${sourceButton(p.source)}<button class="primary" data-review="${p.id}">Проверить и подтвердить</button></article>`).join(''):empty('Новых предложений нет.')}`;const summary=$('#meeting-summary-pane');if(summary)summary.innerHTML=`<div class="section-heading"><h2>Итоги встречи</h2><button data-action="edit-notes">${(meetingData.manual_notes?.revision||0)?'Изменить итоги':'Добавить итоги'}</button></div>${groqSummary()}<p class="muted">Ваши ручные заметки:</p>${manualNotesView()}${meetingSpeakersView()}<h3>Подтверждённые решения</h3>${decisions.length?decisions.map(d=>`<article class="card"><p>${esc(d.text)}</p>${d.source?sourceButton(d.source):''}</article>`).join(''):empty('Решений пока нет. Откройте транскрипт, выберите «Предложить поручение» → «Зафиксировать решение» и подтвердите формулировку.')}<button data-meeting-tab="transcript">Открыть транскрипт</button>`;}
function applyMeetingTab(){const active=H.recording.active?.meeting_id===prefs.meetingId;for(const button of document.querySelectorAll('[data-meeting-tab][role=tab]')){const selected=button.dataset.meetingTab===meetingTab;button.setAttribute('aria-selected',String(selected));button.tabIndex=selected?0:-1;button.classList.toggle('selected',selected);}for(const key of ['summary','transcript','tasks','audio']){const pane=$('#meeting-'+key+'-pane');if(pane)pane.hidden=key!==meetingTab;}document.querySelector('.meeting-tabs')?.classList.toggle('during-recording',active);}
const speakerPalette=['#b6a2f4','#86b9e5','#dba994','#9fcdb8','#e2cc8c','#a7b0ea'];
function participantColor(id){return speakerPalette[Math.abs(Number(id)||0)%speakerPalette.length];}
function meetingOrbitRoster(){const m=W.meetings.find(m=>m.id===prefs.meetingId);return orbitRoster(m,meetingData?.transcript,W.people);}
function participantCircle(m,active){const roster=meetingOrbitRoster(),items=(active?roster.filter(p=>p.person_id!=null):roster).slice(0,8);return `<section class="recording-stage"><div class="participant-orbit" aria-label="Участники и управление записью"><div class="orbit-center"><span class="recording-state" id="circleState">${active?esc(statusLabel(active.state)):'Встреча'}</span><div id="circleClock" class="circle-clock">${time(active?.elapsed_ms||mediaSources().at(-1)?.end||0)}</div><small id="circleSpeaker" role="status" aria-live="polite"></small></div>${items.map((p,i)=>{const angle=i*2*Math.PI/items.length-Math.PI/2;return `<button class="orbit-person" data-orbit-person="${esc(p.key)}" style="left:${50+47*Math.cos(angle)}%;top:${50+47*Math.sin(angle)}%;--speaker:${p.person_id?participantColor(p.person_id):'var(--muted)'}" aria-label="${esc(p.name)}: показать реплики" aria-pressed="false"><span class="orbit-avatar">${esc(p.person_id?p.name.slice(0,1):'?')}</span><strong>${esc(p.name)}</strong><small class="orbit-role">${p.person_id?'Участник':'Имя не подтверждено'}</small></button>`;}).join('')}</div><div id="circleRecordControls" class="circle-record-controls" aria-label="Управление записью встречи"></div>${!m.participants?.length?'<button data-action="edit-meeting">Добавить участников</button>':''}${roster.length>8?'<p class="muted">Все голоса и участники перечислены в итогах ниже.</p>':''}</section>`;}
function renderMeetingCircleStatus(activity){if(!meetingData||!$('#circleSpeaker'))return;const mid=prefs.meetingId,recording=activity?activity.active:H.recording.active,active=recording?.meeting_id===mid?recording:null,player=$('#player');let key=null,candidate=false,label='',playing=player&&!player.paused&&!player.ended;
 if(!active)$('#circleState').textContent='Встреча';
 if(active){if($('#meetingSaved'))$('#meetingSaved').textContent=timePrecise(active.saved_ms);$('#circleClock').textContent=time(active.elapsed_ms);$('#circleState').textContent=statusLabel(active.state);const hint=activity?activity.hint:H.live_voice?.hint;const liveKey=orbitLiveHint(active,hint,true);if(active.state==='paused')label='Пауза · подсветка выключена';else if(active.state!=='recording')label='Ожидаем микрофон';else if(liveKey){candidate=true;key=liveKey;label='Предположительно: '+person(hint.person_id)+' · последние 10 с';}else{key=null;label=H.live_voice?.configured===false?'Модель голосовых подсказок не настроена':hint?.reason||'Ожидаем 10 секунд сохранённого аудио для подсказки';}
 }else if(player){const sources=mediaSources(),source=sources[Number($('#audioTrack')?.value||0)],ms=(source?.start||0)+player.currentTime*1000;const at=orbitAtTime(meetingData.transcript,ms);if(playing){key=at?.key||null;label=at?at.segment?.person_name||meetingOrbitRoster().find(p=>p.key===key)?.name||'Несколько голосов':'В этом месте нет размеченной речи';$('#circleClock').textContent=time(ms);$('#circleState').textContent='Прослушивание';}else if(selectedOrbitPerson){key=selectedOrbitPerson;label='Выбран: '+(meetingOrbitRoster().find(p=>p.key===key)?.name||'Неизвестный голос');}else label='';}
 const listening=active?.state==='recording';
 const level=listening?Math.min(1,Math.sqrt(Math.max(0,(active.level||0)-.015)*5)):0;
 const orbit=$('.participant-orbit');
 orbit?.style.setProperty('--mic-activity',String(level));
 orbit?.classList.toggle('has-unidentified-speech',listening&&!candidate);
 for(const el of document.querySelectorAll('[data-orbit-person]')){const selected=el.dataset.orbitPerson===key;el.classList.toggle('is-speaking',selected&&!!playing&&!active);el.classList.toggle('is-candidate',selected&&candidate);el.classList.toggle('is-selected',el.dataset.orbitPerson===selectedOrbitPerson&&!playing);if(selected&&candidate){
 const strength=level;
 el.style.setProperty('--voice-scale',String(1+strength*.48));
 el.style.setProperty('--voice-opacity',String(strength? .55+strength*.45:0));
 }else{
 el.style.removeProperty('--voice-scale');
 el.style.removeProperty('--voice-opacity');
 }el.setAttribute('aria-pressed',String(el.dataset.orbitPerson===selectedOrbitPerson));}const output=$('#circleSpeaker');if(output.textContent!==label)output.textContent=label;
}
function meetingSpeakersView(){const rows=meetingOrbitRoster();if(!meetingData.transcript)return '';const selected=rows.find(p=>p.key===selectedOrbitPerson);return `<section class="meeting-speakers"><div class="section-heading"><h3>Кто говорил</h3><div class="row-actions">${!prefs.demo&&H.voice?.configured&&(H.voice_data?.profiles||[]).length?`<button data-action="match-voices" ${H.recording.active||H.voice?.running||meetingData.transcript.needs_update?'disabled':''}>Сопоставить голоса</button>`:''}<button data-meeting-tab="transcript">Подтвердить имена голосов</button></div></div><p class="muted">Имена показаны по ручным подтверждениям. Голосовой профиль сам по себе ещё не подписывает реплики.</p><div class="speaker-chips">${rows.map(p=>`<button class="speaker-chip ${selectedOrbitPerson===p.key?'selected':''}" data-orbit-person="${esc(p.key)}" style="--speaker:${p.person_id?participantColor(p.person_id):'var(--muted)'}">${esc(p.name)} · ${time(p.duration_ms)}</button>`).join('')}</div>${selected?`<h4>Реплики: ${esc(selected.name)}</h4>${selected.segments.length?selected.segments.slice(0,6).map(seg=>sourceButton({meeting_id:prefs.meetingId,start_ms:seg.start_ms,quote:seg.text})).join(''):'<p class="muted">Этому участнику пока не назначены реплики. Подтвердите имя голоса в транскрипте.</p>'}${selected.segments.length>6?'<button data-meeting-tab="transcript">Все реплики — в транскрипте</button>':''}`:''}</section>`;}

function seekAudio(ms){const sources=mediaSources();if(!sources.length){error('У этой встречи нет доступного аудио.');return;}const index=Math.max(0,sources.findIndex(s=>s.start<=ms&&s.end>ms));const player=$('#player');$('#meetingSupport').open=true;autoFollow=true;if(Number($('#audioTrack').value)!==index){$('#audioTrack').value=index;player.src='/api/audio/'+sources[index].recording.id;player.onloadedmetadata=()=>{player.currentTime=Math.max(0,(ms-sources[index].start)/1000);player.play().catch(e=>error(e.message));player.onloadedmetadata=null;};player.load();}else{player.currentTime=Math.max(0,(ms-sources[index].start)/1000);player.play().catch(e=>error(e.message));}}
function sourceButton(source){if(!source)return '';return `<blockquote class="quote">${esc(source.quote)}</blockquote><button class="link-button" data-source-meeting="${source.meeting_id}" data-source-ms="${source.start_ms}">Открыть исходную реплику · ${time(source.start_ms)}</button>`;}
function renderApprovals(){const rows=W.proposals.filter(p=>p.status==='pending');return `<p class="muted">Предложения не входят в счётчики задач. Изменения применяются только после вашей проверки.</p>${!prefs.demo?'<div class="callout">Groq предлагает задачи и решения после анализа встречи. Проверьте формулировку, ответственного и срок перед подтверждением.</div>':''}${rows.length?rows.map(p=>{const task=W.tasks.find(t=>t.id===p.task_id);return `<article class="card proposal"><div class="section-heading"><span class="badge blue">${esc(kinds[p.kind])}</span><small>${p.origin==='groq'?'Предложение Groq':p.origin==='demo_ai'?'Демонстрационное AI':'Предложено вручную'}</small></div><h2>${esc(p.title)}</h2>${proposalClarification(p)}<p>${esc(p.description)}</p>${p.kind==='create_task'&&p.due_date?`<p class="muted">Срок ${deadline(p)}</p>`: ''}${task&&p.kind!=='create_task'&&p.kind!=='decision'?`<p>Задача: <button class="link-button" data-task="${task.id}">${esc(task.title)}</button></p><div class="before-after"><div><small>Сейчас</small><p>${esc(proposalValue(p,task,false))}</p></div><div><small>Предложено</small><p>${esc(proposalValue(p,task,true))}</p></div></div>`:''}${sourceButton(p.source)}<div class="row-actions"><button class="primary" data-review="${p.id}">Проверить и подтвердить</button><button data-reject="${p.id}">Отклонить</button></div></article>`}).join(''):empty('Все предложения рассмотрены. Новых задач без вашего подтверждения не появится.')}`;}
function proposalValue(p,t,proposed){const v=proposed?p.proposed||{}:t;if(p.kind==='change_due')return dateLabel(v.due_date)+(v.due_time?' '+v.due_time:'');if(p.kind==='change_assignee')return person(v.assignee_id);if(p.kind==='change_status')return stages(W,t.project_id).find(s=>s.id===v.stage_id)?.title||'Не определён';return p.title;}
function personPhoto(p){
 return p.photo_revision==null
   ? `<span class="avatar person-photo" aria-hidden="true">${esc(p.name.slice(0,1))}</span>`
   : `<img class="avatar person-photo" src="/api/people/photo/${p.id}?v=${p.photo_revision}" alt="">`;
}
function renderPeople(){
 if(!W.people.length)return empty('Участников пока нет.','new-person','Добавить участника');
 const filters=prefs.peopleFilters||{};
 const query=(filters.q||'').trim().toLocaleLowerCase('ru');
 const project=W.projects.find(p=>String(p.id)===filters.project);
 const team=new Set([...(project?.members||[]),project?.owner_id]);
 const people=W.people.filter(p=>
   (!filters.department||p.department===filters.department)&&
   (!filters.organization||p.organization===filters.organization)&&
   (!project||team.has(p.id))&&
   (!query||[p.name,p.patronymic,p.last_name,p.nickname,p.role,p.organization,p.department,p.email,p.phone]
     .filter(Boolean).join(' ').toLocaleLowerCase('ru').includes(query)));
 const values=key=>[...new Set(W.people.map(p=>p[key]).filter(Boolean))].sort((a,b)=>a.localeCompare(b,'ru'));
 return `<div class="filters">
 <label>Поиск<input id="peopleSearch" type="search" placeholder="Имя, псевдоним, контакты" value="${esc(filters.q||'')}"></label>
 <label>Подразделение<select id="peopleDepartment">${option('','Все подразделения',filters.department)}${values('department').map(v=>option(v,v,filters.department)).join('')}</select></label>
 <label>Организация<select id="peopleOrganization">${option('','Все организации',filters.organization)}${values('organization').map(v=>option(v,v,filters.organization)).join('')}</select></label>
 <label>Проект<select id="peopleProject">${option('','Все проекты',filters.project)}${W.projects.map(p=>option(p.id,p.title,filters.project)).join('')}</select></label>
 <button type="button" id="clearPeopleFilters">Сбросить</button></div>
 ${!people.length?empty('Участники не найдены.'):''}
 <div class="table-wrap"><table class="data-table"><thead><tr>
 <th>Участник</th><th>Псевдоним</th><th>Должность</th><th>Подразделение</th><th>Организация</th><th>Контакты</th>
 </tr></thead><tbody>${people.map(p=>`<tr><td><button class="task-title" data-person="${p.id}">
 ${personPhoto(p)}${esc([p.name,p.patronymic,p.last_name].filter(Boolean).join(' '))}</button>
 <span class="inline-detail">${W.tasks.filter(t=>t.assignee_id===p.id&&t.active).length} задач ·
 ${W.meetings.filter(m=>m.participants.includes(p.id)).length} встреч</span>
 ${(H.voice_data?.profiles||[]).some(v=>v.person_id===p.id)?'<span class="badge">Голосовой профиль</span>':''}</td>
 <td>${esc(p.nickname||'—')}</td><td>${esc(p.role||'—')}</td><td>${esc(p.department||'—')}</td><td>${esc(p.organization||'—')}</td>
 <td>${[p.email,p.phone].filter(Boolean).map(esc).join('<br>')||'—'}</td></tr>`).join('')}</tbody></table></div>`;
}
function renderProcessing(){const jobs=W.meetings.flatMap(m=>m.processing?[{...m.processing,meeting:m}]:[]);return `<p class="muted">Запись и распознавание — разные состояния. Ошибка модели не удаляет сохранённое аудио.</p>${H.auto_process_error?`<div class="callout warning">${esc(H.auto_process_error)}</div>`:''}${jobs.length?`<section class="section"><table class="data-table"><thead><tr><th>Встреча</th><th>Состояние</th><th>Попытки</th><th>Действие</th></tr></thead><tbody>${jobs.map(j=>`<tr><td><button class="link-button" data-meeting="${j.meeting_id}">${esc(j.meeting.title)}</button></td><td><span class="badge ${j.status==='failed'?'danger':j.status==='completed'?'success':'blue'}">${statusLabel(j.status)}</span>${j.error?`<p>${esc(humanError(j.error))}</p><small>Аудио остаётся в карточке встречи.</small>`:''}</td><td>${j.attempts}</td><td>${j.status==='failed'?`<button data-retry-job="${j.id}" data-id="${j.meeting_id}" ${prefs.demo||H.speech.running||!!H.recording.active?'disabled':''}>Повторить</button>`:j.status==='pending'?`<button data-run-job="${j.meeting_id}" ${prefs.demo||H.speech.running||!!H.recording.active||!H.speech.configured?'disabled':''}>Запустить</button>`:j.status==='running'&&!H.speech.running?`<button data-recover-job="${j.id}">Восстановить после сбоя</button>`:'—'}</td></tr>`).join('')}</tbody></table></section>`:empty('Заданий пока нет. Завершите запись или импортируйте аудио.')}`;}
function microphoneOptions(){const mic=H.microphone||{};const uid=mic.selected?.uid||'';const devices=mic.devices||[];return option('','Системный микрофон по умолчанию',uid)+(!devices.some(d=>d.uid===uid)&&uid?option(uid,'Выбранный микрофон отключён',uid):'')+devices.map(d=>option(d.uid,d.name+(d.isDefault?' · по умолчанию':''),uid)).join('');}
function microphoneSettings(){return `<section class="section" style="grid-column:1/-1"><h2>Микрофон</h2><form id="microphoneForm"><div class="form-grid"><label class="wide">Устройство ввода<select name="uid" id="microphoneSelect">${microphoneOptions()}</select></label><div class="row-actions wide"><button type="submit" ${H.recording.active||['starting','testing'].includes(H.microphone?.test?.state)||prefs.demo?'disabled':''}>Сохранить микрофон</button><button type="button" id="refreshMicrophones">Обновить список</button><button type="button" id="testMicrophone" ${H.recording.active||H.speech.running||prefs.demo?'disabled':''}>Проверить 5 секунд</button></div></div></form><p class="muted">Проверка включит выбранный микрофон на 5 секунд без сохранения аудио и без распознавания. Говорите обычным голосом. Смена устройства действует для следующей записи.</p><div id="microphoneTestStatus" aria-live="polite"></div></section>`;}
function renderMicrophoneTest(){const box=$('#microphoneTestStatus');if(!box)return;const t=H.microphone?.test;if(!t||!t.state){box.textContent='Проверка ещё не запускалась.';return;}const active=['starting','testing'].includes(t.state);const level=Math.round(Math.min(100,(t.level||0)*250));box.innerHTML=`<p>${esc(t.device?.name||'Микрофон')} · ${esc(({starting:'Ожидаем разрешение и запуск',testing:'Проверяем уровень',completed:(t.peak||0)>0.002?'Проверка завершена: сигнал обнаружен':'Проверка завершена: сигнал очень тихий или отсутствует',failed:'Ошибка проверки'})[t.state]||t.state)}</p>${active?`<div class="meter" role="meter" aria-label="Уровень при проверке микрофона" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${level}"><span style="width:${level}%"></span></div>`:''}${t.error?`<p class="callout danger">${esc(t.error)}</p>`:''}`;const button=$('#testMicrophone');if(button)button.disabled=active||!!H.recording.active||H.speech.running||prefs.demo;}
function voiceMatchingSettings(){const s=H.voice_data?.settings||{enabled:false,threshold:0.75,margin:0.1};return `<section class="section" style="grid-column:1/-1"><h2>Сопоставление говорящих</h2><form id="voiceMatchingSettingsForm"><label class="check"><input name="enabled" type="checkbox" ${s.enabled?'checked':''}>После обработки встречи предлагать имена по локальным голосовым профилям</label><div class="form-grid"><label>Минимальное сходство<input name="threshold" type="number" min="0.5" max="0.99" step="0.01" value="${esc(s.threshold)}" required></label><label>Минимальный отрыв от второго кандидата<input name="margin" type="number" min="0.05" max="0.5" step="0.01" value="${esc(s.margin)}" required></label></div><p class="muted">Подсказки требуют ручного подтверждения и не заменяют ручные назначения. Сходство — не вероятность личности. Начальные пороги нужно проверить на ваших голосах; при сомнении имя остаётся неизвестным. Автоматический режим действует для следующих обработок, текущую встречу можно сопоставить отдельной кнопкой.</p><button type="submit" ${prefs.demo?'disabled':''}>Сохранить сопоставление</button>${H.voice?.interrupted&&!prefs.demo?'<p class="callout warning">В БД остался прерванный голосовой обработчик. Подтвердите завершение прежних процессов перед восстановлением.</p><button type="button" data-action="recover-voice-matching">Восстановить голосовую очередь</button>':''}</form></section>`;}
function speechSettings(){const s=H.speech.settings||{},local=s.local_model||(H.models||[]).find(p=>p.includes('large-v3-turbo'))||(H.models||[])[0]||'';return `<section class="section" style="grid-column:1/-1"><h2>Модель распознавания</h2><form id="speechSettingsForm"><div class="form-grid"><label class="wide">Где распознавать<select name="provider">${option('local','На этом Mac',s.provider||'local')}${option('cloud','Облачный API',s.provider)}</select></label><label class="wide">Режим обработки по умолчанию<select name="processing_mode">${option('post','После встречи',s.processing_mode||'post')}${option('live','Live: предварительный текст во время записи',s.processing_mode)}</select></label>
<p class="muted wide">Live работает локально: один обработчик, 2 потока CPU, ограниченная очередь. При отставании обработка откладывается до конца встречи. Итоговый транскрипт создаётся отдельно.</p><label class="wide">Локальная модель<select id="localModelSelect">${(H.models||[]).map(p=>option(p,p.split('/').pop(),local)).join('')}</select></label><label class="wide">Путь к локальной модели<input name="local_model" id="localModelPath" value="${esc(local)}" placeholder="/полный/путь/ggml-model.bin"></label><p class="muted wide">Можно выбрать установленную модель или указать свой файл Whisper GGML. Проверка формата при сохранении не гарантирует совместимость всех весов.</p><label class="wide">Сервис<select id="cloudPreset"><option value="custom">Свой совместимый API</option><option value="openai">OpenAI</option></select></label><label class="wide">Полный адрес API<input name="url" value="${esc(s.url||'https://api.openai.com/v1/audio/transcriptions')}" placeholder="https://…/v1/audio/transcriptions"></label><label>Имя облачной модели<input name="model" value="${esc(s.model||'gpt-transcribe')}" placeholder="whisper-1"></label><label>Формат ответа<select name="format">${option('json','JSON: текст',s.format||'json')}${option('verbose_json','Verbose JSON: текст и таймкоды',s.format)}</select></label><label class="wide">Ключ API<input name="api_key" type="password" autocomplete="off" placeholder="${H.speech.key_present?'Ключ задан; оставьте пустым, чтобы сохранить':'Введите ключ сервиса'}"></label><label class="check wide"><input name="clear_key" type="checkbox">Удалить ключ из памяти</label><p class="callout warning wide">В облачном режиме сохранённое аудио отправляется выбранному сервису при ручной или автоматической обработке. Возможна оплата по тарифам сервиса. Ключ хранится только до перезапуска сервера. Максимум WAV — 24 МБ; без таймкодов от API текст показан одним блоком на всю запись.</p><p class="muted wide">Поддерживается API multipart /audio/transcriptions. Для whisper-1 доступны таймкоды (verbose_json); для других моделей выбирайте поддерживаемый ими формат. Настройки действуют со следующей обработки; старый транскрипт сохраняется.</p></div><button class="primary" type="submit" ${H.speech.running||H.recording.active||prefs.demo?'disabled':''}>Сохранить модель</button></form><p>Выбрано: ${esc(s.provider==='cloud'?(s.model||'Облачный API'):(s.local_model||local).split('/').pop())}</p></section>`;}
function renderSettings(){const s=W.settings;return `<div class="settings-grid">${microphoneSettings()}${speechSettings()}${groqSettings()}${voiceMatchingSettings()}<section class="section"><h2>Рабочее пространство</h2><form id="settingsForm"><div class="form-grid"><label class="wide">Часовой пояс<input name="timezone" list="timezones" value="${esc(s.timezone)}" required><datalist id="timezones">${(Intl.supportedValuesOf?.('timeZone')||['Europe/Moscow','UTC']).map(z=>`<option value="${esc(z)}"></option>`).join('')}</datalist></label><label>Кто я<select name="me_id">${personOptions(s[prefs.demo?'demo_me_id':'me_id'])}</select></label><label>Тема<select name="theme">${[['system','Как в системе'],['light','Светлая'],['dark','Тёмная']].map(([k,v])=>option(k,v,s.theme)).join('')}</select></label><label class="wide">Размер основного текста: ${s.font_size} px<input name="font_size" type="range" min="14" max="24" value="${s.font_size}"></label><label class="check wide"><input name="auto_process" type="checkbox" ${s.auto_process?'checked':''}>Распознавать после остановки записи</label><p class="muted wide">Дата без времени действует до конца дня в этом часовом поясе. Пауза проекта не снимает просрочку задач.</p></div><button type="submit" class="primary">Сохранить настройки</button></form></section><section class="section"><h2>Установка и возможности</h2><p><span class="badge ${H.recording.available?'success':'warning'}">Микрофон: ${H.recording.available?'адаптер найден':'нужна установка'}</span></p><p><span class="badge ${H.speech.configured?'success':'warning'}">Распознавание: ${H.speech.configured?'модели настроены':'не настроено'}</span></p><p>Разделение голосов: ${H.speech.diarization_enabled?'включено':'выключено'} · VAD: ${H.speech.vad_enabled?'включён':'выключен'}</p><p>На диске: ${H.free_bytes==null?'нет данных':(H.free_bytes/1024**3).toFixed(1)+' ГБ свободно'}</p><details><summary>Проверка установки на Mac</summary><p>В Terminal из папки проекта:</p><pre class="diagnostic">bash scripts/setup-macos.sh --with-microphone\nbash scripts/start-macos.sh</pre><p class="muted">Модель можно изменить в разделе «Модель распознавания». Экран не заявляет загрузку модели до успешной обработки.</p>${H.speech.configuration_error?`<pre class="diagnostic">${esc(H.speech.configuration_error)}</pre>`:''}</details><h3 style="margin-top:20px">Пока недоступно</h3><p class="muted">Системный звук, применение имён без подтверждения ещё не реализованы. Их элементы не запускают демонстрацию вместо реальной функции.</p></section><section class="section"><h2>Сохранённые выборки</h2>${(s.saved_views||[]).length?s.saved_views.map((v,i)=>`<p>${esc(v.name)} <button data-delete-view="${i}">Удалить</button></p>`).join(''):empty('Сохраните фильтры в разделе задач.')}</section><section class="section"><h2>Запись и закрытие окна</h2><p>Переход между разделами и закрытие вкладки не останавливают запись. Активная сессия ограничена выбранным временем. Перед завершением сервера остановите запись кнопкой и дождитесь сохранения.</p><p>Демонстрационный режим хранит отдельный набор данных и не запускает микрофон.</p><button data-action="demo-mode">${prefs.demo?'Вернуться к моим данным':'Открыть демонстрацию'}</button></section></div>`;}
function showDialog(title,content,onSubmit){
 const modal=$('#modal');
 modal.classList.remove('assistant-dialog');
 if(modal.open)modal.close();
 modal.innerHTML=`<div class="dialog-heading"><h2 id="modalTitle">${esc(title)}</h2><button type="button" data-dialog-close aria-label="Закрыть окно">×</button></div><div id="modalError" role="alert" hidden class="callout danger"></div>${onSubmit?`<form id="modalForm">${content}<div class="dialog-actions"><button type="button" data-close-modal>Отмена</button><button type="submit" class="primary">Сохранить</button></div></form>`:content}`;
 const form=modal.querySelector('#modalForm');
 let saving=false;
 const requestClose=()=>{
   if(saving)return;
   if(form?.dataset.dirty==='true'){
     confirmUnsaved({
       discard:closeDialog,
       save:dialog=>{dialog.close();form.requestSubmit();}
     });
   }else closeDialog();
 };
 modal.querySelector('[data-dialog-close]').onclick=()=>{
   const close=modal.querySelector('[data-close-modal]');
   if(close)close.click();else requestClose();
 };
 modal.querySelector('[data-close-modal]')?.addEventListener('click',requestClose);
 modal.oncancel=event=>{event.preventDefault();requestClose();};
 if(form){
   const markDirty=()=>{form.dataset.dirty='true';};
   form.addEventListener('input',markDirty);
   form.addEventListener('change',markDirty);
   form.onsubmit=async event=>{
     event.preventDefault();
     if(saving)return;
     saving=true;
     const button=form.querySelector('[type=submit]');
     button.disabled=true;
     try{await onSubmit(form);if(form.isConnected)closeDialog();}
     catch(err){
       const message=modal.querySelector('#modalError');
       if(form.isConnected){message.textContent=humanError(err.message);message.hidden=false;}
     }finally{saving=false;button.disabled=false;}
   };
 }
 modal.showModal();
}
function closeDialog(){$('#modal').close();}
function formObject(form){return Object.fromEntries(new FormData(form));}
function dependencyOptions(task,projectId=task.project_id){
 return W.tasks.filter(other=>other.id!==task.id&&(other.project_id??null)===(projectId??null))
   .map(other=>option(other.id,other.title,(task.dependencies||[]).includes(other.id)?other.id:null)).join('');
}
function taskFields(t,approval=false){return `<div class="form-grid"><label class="wide">Название<input name="title" maxlength="500" required value="${esc(t.title)}"></label><label class="wide">Описание<textarea name="description">${esc(t.description)}</textarea></label><label>Проект<select name="project_id" data-draft-project>${projectOptions(t.project_id)}</select></label><label>Ответственный<select name="assignee_id">${personOptions(t.assignee_id)}</select></label><label>Статус<select name="stage_id" id="${approval?'approvalStage':'draftStage'}">${stages(W,t.project_id).map(s=>option(s.id,s.title,t.stage_id)).join('')}</select></label><label>Приоритет<select name="priority">${Object.entries(priorities).map(([k,v])=>option(k,v,t.priority)).join('')}</select></label><label>Срок — дата<input name="due_date" type="date" value="${esc(t.due_date)}"></label><label>Время (необязательно)<input name="due_time" type="time" value="${esc(t.due_time)}"></label>${!approval?`<label>Автор<select name="author_id">${personOptions(t.author_id)}</select></label><label>Зависимости<select name="dependencies" multiple size="3">${dependencyOptions(t)}</select></label><label class="check wide"><input name="blocked" type="checkbox" ${t.blocked?'checked':''}>Заблокировано (этап сохраняется)</label><label class="wide">Причина блокировки<input name="blocked_reason" value="${esc(t.blocked_reason)}"></label>`:''}</div>`;}
function readTask(form,base){const v=formObject(form);return {...base,title:v.title,description:v.description,project_id:v.project_id?Number(v.project_id):null,assignee_id:v.assignee_id?Number(v.assignee_id):null,author_id:v.author_id?Number(v.author_id):base.author_id||null,stage_id:v.stage_id,priority:v.priority,due_date:v.due_date||null,due_time:v.due_date?(v.due_time||null):null,blocked:form.elements.blocked?.checked||false,blocked_reason:v.blocked_reason||'',dependencies:form.elements.dependencies?[...form.elements.dependencies.selectedOptions].map(o=>Number(o.value)).concat((v.project_id?Number(v.project_id):null)===(base.project_id??null)?(base.dependencies||[]).filter(id=>![...form.elements.dependencies.options].some(o=>Number(o.value)===id)):[]):(base.dependencies||[])};}
function openTask(id=null){guard(()=>{const current=id?W.tasks.find(t=>t.id===Number(id)):null;draft=structuredClone(current||taskDefaults(W,prefs.section==='projects'?prefs.projectId:null));prefs.selectedTask=current?.id||null;dirty=false;savePrefs();renderInspector();$('#inspector input[name=title]').focus();});}
document.addEventListener('keydown',event=>{
 if(event.key==='Escape'&&draft&&!event.defaultPrevented&&!document.querySelector('dialog[open]')){
   event.preventDefault();
   guard(closeInspector);
 }
});
function closeInspector(){const returnId=prefs.selectedTask;document.body.classList.remove('inspector-open');draft=null;dirty=false;prefs.selectedTask=null;$('#inspector').hidden=true;savePrefs();const returnTarget=returnId?document.querySelector(`#main [data-task="${returnId}"]`):null;(returnTarget||$('#main')).focus({preventScroll:true});}
function renderInspector(){if(!draft)return;document.body.classList.add('inspector-open');const root=$('#inspector');root.hidden=false;root.innerHTML=`<div class="inspector-head"><h2>${draft.id?'Карточка задачи':'Новая задача'}</h2><button id="closeInspector" aria-label="Закрыть карточку задачи">Закрыть ×</button></div><form id="taskForm">${taskFields(draft)}${draft.sources?.length?`<section><h3>Источник</h3>${draft.sources.map(sourceButton).join('')}</section>`:'<small>Создана вручную</small>'}<div id="taskFormError" role="alert" hidden class="callout danger"></div><div class="form-actions"><button type="button" id="cancelTask">Отмена</button><button class="primary" type="submit">Сохранить</button></div></form>${draft.id?'<button id="taskHistory" class="link-button" style="margin-top:18px">Показать историю изменений</button><div id="taskHistoryBody" class="task-history"></div>':''}`;
 $('#closeInspector').onclick=()=>guard(closeInspector);$('#cancelTask').onclick=()=>guard(closeInspector);$('#taskForm').oninput=()=>{dirty=true;};$('#taskForm').onchange=e=>{dirty=true;if(e.target.name==='project_id'){const project=e.target.value?Number(e.target.value):null;const stage=$('#draftStage');stage.innerHTML=stages(W,project).map(s=>option(s.id,s.title,stage.value)).join('');const dependencies=e.target.form.elements.dependencies;const selected=[...dependencies.selectedOptions].map(o=>Number(o.value));dependencies.innerHTML=dependencyOptions({...draft,dependencies:selected},project);}};$('#taskForm').onsubmit=async e=>{e.preventDefault();e.submitter.disabled=true;try{await saveTaskDraft();}catch(err){$('#taskFormError').textContent=err.message;$('#taskFormError').hidden=false;}finally{const button=$('#taskForm button[type=submit]');if(button)button.disabled=false;}};
 $('#taskHistory')?.addEventListener('click',async()=>{try{const history=await api.command('history',{entity:'tasks',id:draft.id},prefs.demo);$('#taskHistoryBody').innerHTML=history.map(h=>`<article><small>${stamp(h.created_at)}</small><p>${h.before?'Изменено':'Создано'}: ${esc(h.after.title)}</p>${h.before&&(h.before.due_date!==h.after.due_date||h.before.due_time!==h.after.due_time)?`<p>Срок: ${dateLabel(h.before.due_date)} ${esc(h.before.due_time||'')} → ${dateLabel(h.after.due_date)} ${esc(h.after.due_time||'')}</p>`:''}${h.before&&h.before.stage_id!==h.after.stage_id?`<p>Этап: ${esc(h.before.stage_id)} → ${esc(h.after.stage_id)}</p>`:''}${h.before&&h.before.assignee_id!==h.after.assignee_id?`<p>Ответственный: ${esc(person(h.before.assignee_id))} → ${esc(person(h.after.assignee_id))}</p>`:''}</article>`).join('');}catch(e){error(e.message);}});
}
async function saveTaskDraft(){if(!draft)return;const form=$('#taskForm');if(!form.reportValidity())throw Error('Проверьте поля задачи');const data=readTask(form,draft);const creating=!draft.id;const response=await api.command('save_task',{id:draft.id,revision:draft.revision,data},prefs.demo);dirty=false;draft=structuredClone(response);prefs.selectedTask=response.id;if(creating&&prefs.section==='projects'&&prefs.projectId===response.project_id){projectTab='tasks';prefs.taskFilters={};}savePrefs();await refresh(false);renderAll();renderInspector();flash('Задача сохранена');}
function newPerson(){showDialog('Новый участник','<label>Имя<input name="name" autocomplete="name" required></label>',async form=>{const {id}=await perform(()=>api.command('add_person',{name:formObject(form).name},prefs.demo),'Участник добавлен');openPerson(id);});}
function renderVoicePersonStatus(){
 const box=$('#voicePersonStatus');if(!box)return;const id=Number(box.dataset.person),profiles=(H.voice_data?.profiles||[]).filter(p=>p.person_id===id),jobs=(H.voice_data?.jobs||[]).filter(j=>j.person_id===id),latest=jobs[0];
 const key=JSON.stringify([profiles,latest,H.voice?.configured,H.voice?.configuration_error,H.voice?.running,jobs.some(j=>j.state==='running')]);
 if(box.dataset.key===key)return;
 box.dataset.key=key;
 box.innerHTML=profiles.length?'<p><span class="badge success">Голосовой профиль зарегистрирован</span></p>':'<p class="muted">Голосовой профиль пока не зарегистрирован.</p>';
 if(profiles.length)box.innerHTML+=`<details><summary>Данные голосового профиля</summary>${profiles.map(p=>`<p>Модель ${esc(p.model_sha256.slice(0,12))} · образцов: ${p.sample_count} · версия ${p.revision}</p>`).join('')}</details>`;
 if(latest)box.innerHTML+=`<p>Последний образец: ${esc(({pending:'в очереди',running:'проверяем и создаём профиль',completed:'сохранён',failed:'ошибка'})[latest.state]||latest.state)}</p>${latest.error?`<p class="callout warning">${esc(latest.error)}</p>`:''}`;
 if(!H.voice?.configured)box.innerHTML+=`<p class="callout warning">${esc(H.voice?.configuration_error||'Адаптер голосовых профилей не настроен')}</p>`;
 const retry=$('#voiceRetry');if(retry){retry.hidden=latest?.state!=='failed';retry.onclick=async()=>{try{await api.request('voice/retry',{id:latest.id});await refresh(false);renderVoicePersonStatus();}catch(e){error(e.message);}};}
 const recover=$('#voiceRecover');if(recover){recover.hidden=!jobs.some(j=>j.state==='running')||H.voice?.running;recover.onclick=async()=>{if(!confirm('Прежний процесс регистрации голосового профиля завершён?'))return;try{await api.request('voice/recover',{confirmed_stopped:true});await refresh(false);renderVoicePersonStatus();}catch(e){error(e.message);}};}
}
function openPerson(id,returnToMeeting=null){
 const p=W.people.find(p=>p.id===id);if(!p)return;
 const details=[['name','Имя'],['last_name','Фамилия'],['patronymic','Отчество'],['nickname','Псевдоним'],['role','Должность или роль'],['organization','Организация'],['department','Подразделение'],['email','Электронная почта'],['phone','Телефон']];
 const fields=details.map(([key,label])=>`<label>${label}<input name="${key}" value="${esc(p[key]??'')}" maxlength="254" ${key==='name'?'required':''}></label>`).join('');
 showDialog(p.name,`<div class="row-actions"><span id="personPhotoPreview">${personPhoto(p)}</span>
 ${!prefs.demo?`<label>Фото<input id="personPhotoFile" type="file" accept="image/*"></label>
 <button type="button" id="removePersonPhoto" ${p.photo_revision==null?'hidden':''}>Удалить фото</button>`:''}</div>
 <form id="personDetailsForm"><h3>Данные участника</h3>${fields}
 <label>Заметки<textarea name="notes" maxlength="4000" rows="3">${esc(p.notes??'')}</textarea></label>
 <button class="primary" type="submit">Сохранить данные участника</button></form><p>Текущих задач: ${filterTasks(W,{active:true,assignees:[String(id)]}).length}</p><p>Встреч с участником: ${W.meetings.filter(m=>m.participants.includes(id)).length}</p>
 <h3>Голосовой профиль</h3><div id="voicePersonStatus" data-person="${id}" aria-live="polite"></div>
 <p class="muted">Образец: 6–60 секунд, один голос, без музыки и других людей. Рекомендуется 10–30 секунд обычной речи. Проверяются длительность, уровень и перегрузка. Обработка и хранение выполняются на этом Mac.</p>
 ${!prefs.demo?`<section class="voice-enrollment"><h3>Запишите три фразы</h3><label>Микрофон для образца<select id="voiceRecordDevice">${microphoneOptions()}</select></label><label class="check"><input type="checkbox" id="voiceRecordConsent">Участник согласен на запись образца, локальное хранение и создание голосового профиля после подтверждения.</label><div id="voiceCaptureStatus" data-person="${id}"></div><p class="muted voice-draft-note">Запись остановится через 45 секунд. До сохранения профиль не создаётся. Закрытие этой карточки удалит временный образец; при закрытии вкладки он удалится не позже чем через 10 минут после записи.</p></section><details class="voice-upload-extra"><summary>Другой способ: загрузить готовый файл</summary><label>Аудиофайл образца (до 16 МБ)<input type="file" id="voiceFile" accept=".wav,.m4a,.mp3,.aac,.flac"></label>
 <label class="check"><input type="checkbox" id="voiceConsent">Участник согласен на локальное хранение образца и создание голосового профиля.</label>
 <label class="check"><input type="checkbox" id="voiceSolo">В образце говорит только этот участник.</label>
 <div class="row-actions"><button id="voiceUpload" ${!H.voice?.configured?'disabled':''}>Загрузить голосовой образец</button></div></details><div class="row-actions"><button id="voiceRetry" hidden>Повторить обработку</button><button id="voiceRecover" hidden>Восстановить очередь</button><button id="voiceDelete" class="danger">Удалить образцы и профили</button></div>`:'<p>В демонстрационном режиме регистрация голоса недоступна.</p>'}
 <div class="callout">Из реплики встречи можно создать образец этого голоса. Сопоставление с профилями предлагает имена, которые нужно подтвердить в транскрипте. При низком или неоднозначном сходстве имя остаётся неизвестным.</div>
 <div class="dialog-actions">${returnToMeeting?'':'<button id="personTasks">Открыть задачи</button>'}<button data-close-modal>${returnToMeeting?'Вернуться к встрече':'Закрыть'}</button></div>`,null);
 const photoInput=$('#personPhotoFile'), removePhoto=$('#removePersonPhoto');
 const savePhoto=async file=>{
   photoInput.disabled=removePhoto.disabled=true;
   try{
     let photo=null;
     if(file){
       const bitmap=await createImageBitmap(file);
       const scale=Math.min(1,512/Math.max(bitmap.width,bitmap.height));
       const canvas=document.createElement('canvas');
       canvas.width=Math.max(1,Math.round(bitmap.width*scale));
       canvas.height=Math.max(1,Math.round(bitmap.height*scale));
       try{canvas.getContext('2d').drawImage(bitmap,0,0,canvas.width,canvas.height);}
       finally{bitmap.close();}
       photo=await new Promise(resolve=>canvas.toBlob(resolve,'image/jpeg',0.82));
       if(!photo)throw Error('Не удалось подготовить фото.');
     }
     const response=await fetch(`/api/people/photo/${id}`,{method:'POST',headers:{'Content-Type':'image/jpeg'},body:photo});
     if(!response.ok)throw Error((await response.json()).error||'Не удалось сохранить фото.');
     await refresh(false);
     renderAll();
     const updated=W.people.find(person=>person.id===id);
     if(updated&&photoInput.isConnected){
       $('#personPhotoPreview').innerHTML=personPhoto(updated);
       removePhoto.hidden=updated.photo_revision==null;
       $('#modalError').hidden=true;
     }
   }catch(err){if(photoInput.isConnected)voiceCaptureError(err.message);}
   finally{photoInput.value='';photoInput.disabled=removePhoto.disabled=false;}
 };
 if(photoInput){
   photoInput.onchange=()=>{if(photoInput.files[0])void savePhoto(photoInput.files[0]);};
   removePhoto.onclick=()=>void savePhoto(null);
 }
 $('#personDetailsForm').onsubmit=async e=>{
   e.preventDefault();
   const button=e.submitter;
   button.disabled=true;
   try{
     await api.command('save_person',{id,data:formObject(e.currentTarget)},prefs.demo);
     await refresh(false);
     renderAll();
     const updated=W.people.find(person=>person.id===id);
     if(updated&&$('#personDetailsForm'))$('#modalTitle').textContent=updated.name;
     flash('Данные участника сохранены');
   }catch(err){
     const message=$('#modalError');
     if(message){message.textContent=err.message;message.hidden=false;}
   }finally{button.disabled=false;}
 };
 if($('#personTasks'))$('#personTasks').onclick=()=>closeVoicePerson(id,()=>{closeDialog();prefs.taskFilters={assignees:[String(id)],active:true};navigate('tasks');});const oldClose=$('#modal [data-close-modal]');const freshClose=oldClose.cloneNode(true);oldClose.replaceWith(freshClose);const leave=()=>closeVoicePerson(id,returnToMeeting||closeDialog);freshClose.onclick=leave;$('#modal').oncancel=e=>{e.preventDefault();leave();};
 if(!prefs.demo){$('#voiceUpload').onclick=async()=>{const file=$('#voiceFile').files?.[0];if(!file||!$('#voiceConsent').checked||!$('#voiceSolo').checked){$('#modalError').textContent='Выберите файл и подтвердите согласие участника и запись одного голоса.';$('#modalError').hidden=false;return;}const button=$('#voiceUpload');button.disabled=true;try{await api.enrollVoice(id,file);$('#voiceFile').value='';$('#voiceConsent').checked=false;$('#voiceSolo').checked=false;$('#modalError').hidden=true;await refresh(false);renderVoicePersonStatus();flash('Образец добавлен в очередь локальной обработки');}catch(e){$('#modalError').textContent=e.message;$('#modalError').hidden=false;}finally{button.disabled=false;}};
 $('#voiceDelete').onclick=async()=>{if(!confirm('Удалить все голосовые образцы и профили этого участника из приложения? Участник и история встреч останутся.'))return;try{await api.request('voice/delete',{person_id:id,confirmed:true});await refresh(false);renderVoicePersonStatus();flash('Голосовые образцы и профили удалены');}catch(e){$('#modalError').textContent=e.message;$('#modalError').hidden=false;}};
 }renderVoicePersonStatus();renderVoiceCaptureStatus();
}
function newMeeting(edit=false,draft=null){
 const meeting=edit?W.meetings.find(m=>m.id===prefs.meetingId):null;
 const participants=new Set(draft?.participants||meeting?.participants||[]);
 const offers=new Set(draft?.offers||[]);
 showDialog(meeting?'Сведения о встрече':'Новая встреча',`
  <label>Название<input name="title" required value="${esc(draft?.title??meeting?.title??'')}" placeholder="Например, планирование проекта"></label>
  <label>Проект<select name="project_id">${projectOptions(draft?.project_id??meeting?.project_id??prefs.projectId)}</select></label>
  <section aria-label="Участники"><h3>Участники</h3><div id="meetingPeopleList"></div>
   <div id="meetingPeoplePicker">
    <div class="row-actions"><label>Из списка<select id="meetingPersonChoice"></select></label><button type="button" id="meetingAddPerson">Добавить</button></div>
    <div class="row-actions"><label>Новый участник<input id="meetingNewPerson" placeholder="Имя"></label><button type="button" id="meetingCreatePerson">Создать</button></div>
   </div>
  </section>`,async form=>{
  const v=formObject(form);
  const result=await perform(()=>api.command('save_meeting',{id:meeting?.id,data:{title:v.title,project_id:v.project_id?Number(v.project_id):null,participants:[...participants]}},prefs.demo),'Встреча сохранена',false);
  navigate('meetings',{meeting:result.id});
 });
 const form=$('#modalForm'),list=$('#meetingPeopleList'),choice=$('#meetingPersonChoice');
 const draw=()=>{
  const available=W.people.filter(p=>!participants.has(p.id));
  choice.innerHTML=option('','Выберите участника','')+available.map(p=>option(p.id,p.name,'')).join('');
  choice.disabled=!available.length;
  $('#meetingAddPerson').disabled=true;
  list.innerHTML=[...participants].map(id=>`<div class="row-actions"><span>${esc(person(id))}</span><button type="button" data-meeting-remove="${id}" aria-label="Убрать ${esc(person(id))}">×</button>${offers.has(id)&&!prefs.demo&&!(H.voice_data?.profiles||[]).some(p=>p.person_id===id)?`<button type="button" data-meeting-enroll="${id}">Записать образец голоса</button>`:''}</div>`).join('')||'<p class="muted">Участники пока не добавлены.</p>';
 };
 choice.onchange=()=>{$('#meetingAddPerson').disabled=!choice.value;};
 $('#meetingAddPerson').onclick=()=>{
  if(!choice.value)return;
  participants.add(Number(choice.value));form.dataset.dirty='true';draw();
 };
 list.onclick=event=>{
  const button=event.target.closest('button');
  if(!button)return;
  if(button.dataset.meetingRemove){
   participants.delete(Number(button.dataset.meetingRemove));form.dataset.dirty='true';draw();
  }
  if(button.dataset.meetingEnroll){
   const values=formObject(form);
   const saved={...values,participants:[...participants],offers:[...offers]};
   openPerson(Number(button.dataset.meetingEnroll),()=>newMeeting(edit,saved));
  }
 };
 const input=$('#meetingNewPerson'),create=$('#meetingCreatePerson');
 input.onkeydown=event=>{if(event.key==='Enter'){event.preventDefault();create.click();}};
 create.onclick=async()=>{
  const name=input.value.trim();
  if(!name){input.focus();return;}
  const submit=form.querySelector('[type="submit"]');
  create.disabled=submit.disabled=true;
  try{
   const {id}=await api.command('add_person',{name},prefs.demo);
   participants.add(id);offers.add(id);form.dataset.dirty='true';input.value='';
   if(!W.people.some(p=>p.id===id))W.people.push({id,name});
   if(!form.isConnected)return;
   const saved={...formObject(form),participants:[...participants],offers:[...offers]};
   openPerson(id,()=>newMeeting(edit,saved));
  }catch(e){
   if(form.isConnected){$('#modalError').textContent=humanError(e.message);$('#modalError').hidden=false;}
  }finally{create.disabled=submit.disabled=false;}
 };
 draw();
}
function editProject(id=null){const current=W.projects.find(p=>p.id===id);const p=structuredClone(current||{title:'',description:'',goal:'',next_milestone:'',next_milestone_date:null,blocker:'',owner_id:null,members:[],start_date:W.today,end_date:null,status:'planned',stages:W.default_stages});let pipeline=structuredClone(p.stages),removed=[];
 showDialog(current?'Настройки проекта':'Новый проект',`<div class="form-grid"><label class="wide">Название<input name="title" required value="${esc(p.title)}"></label><label class="wide">Цель проекта<textarea name="goal" maxlength="4000" placeholder="Какой результат должен дать проект">${esc(p.goal||'')}</textarea></label><label class="wide">Описание<textarea name="description">${esc(p.description)}</textarea></label><label class="wide">Ближайший этап<input name="next_milestone" maxlength="500" value="${esc(p.next_milestone||'')}" placeholder="Например, согласовать прототип"></label><label>Срок ближайшего этапа<input name="next_milestone_date" type="date" value="${esc(p.next_milestone_date||'')}"></label><label class="wide">Препятствия<textarea name="blocker" maxlength="4000" placeholder="Что мешает двигаться дальше">${esc(p.blocker||'')}</textarea></label><label>Владелец<select name="owner_id">${personOptions(p.owner_id)}</select></label><label>Статус<select name="status">${Object.entries(projectStatuses).map(([k,v])=>option(k,v,p.status)).join('')}</select></label><label>Дата начала<input name="start_date" type="date" value="${esc(p.start_date)}"></label><label>Плановое завершение<input name="end_date" type="date" value="${esc(p.end_date)}"></label><label class="wide">Материалы<textarea name="materials" maxlength="8000" placeholder="Перечень материалов, ссылки и примечания">${esc(p.materials||'')}</textarea></label><fieldset class="wide"><legend>Команда проекта</legend><p class="muted">Отметьте участников проекта. Исполнитель отдельной задачи выбирается в её карточке.</p>${W.people.map(person=>`<label class="check"><input type="checkbox" name="members" value="${person.id}" ${(p.members||[]).includes(person.id)?'checked':''}>${esc(person.name)}</label>`).join('')||'<p class="muted">Добавьте людей в разделе «Участники».</p>'}</fieldset></div><h3>Пайплайн проекта</h3><p class="muted">Системный тип определяет завершение задачи независимо от названия этапа.</p><div id="pipelineEditor"></div><button type="button" id="addStage">＋ Добавить этап</button><div id="pipelineMigrations"></div>`,async form=>{syncPipeline();const v=formObject(form);const migrate={};for(const s of removed){migrate[s.id]=form.elements['migrate-'+s.id]?.value;}await perform(()=>api.command('save_project',{id:p.id,revision:p.revision,data:{...p,title:v.title,description:v.description,materials:v.materials,goal:v.goal,next_milestone:v.next_milestone,next_milestone_date:v.next_milestone_date||null,blocker:v.blocker,owner_id:v.owner_id?Number(v.owner_id):null,status:v.status,start_date:v.start_date||null,end_date:v.end_date||null,members:new FormData(form).getAll('members').map(Number),stages:pipeline},migrate_stages:migrate},prefs.demo),'Проект сохранён');});
 function syncPipeline(){for(const row of $('#pipelineEditor').children){const stage=pipeline.find(s=>s.id===row.dataset.stage);if(stage){stage.title=row.querySelector('input').value;stage.kind=row.querySelector('select').value;}}}
 function paint(){const container=$('#pipelineEditor');container.className='pipeline-editor';container.innerHTML=pipeline.map((s,i)=>`<div class="pipeline-line" data-stage="${esc(s.id)}"><label><span class="sr-only">Название этапа</span><input value="${esc(s.title)}" required></label><label><span class="sr-only">Системный тип</span><select>${[['active','Рабочий'],['done','Завершено'],['cancelled','Отменено']].map(([k,v])=>option(k,v,s.kind)).join('')}</select></label><button type="button" data-pipe="up" data-id="${esc(s.id)}" ${i===0?'disabled':''} aria-label="Этап выше">↑</button><button type="button" data-pipe="down" data-id="${esc(s.id)}" ${i===pipeline.length-1?'disabled':''} aria-label="Этап ниже">↓</button><button type="button" data-pipe="remove" data-id="${esc(s.id)}" aria-label="Удалить этап ${esc(s.title)}">×</button></div>`).join('');const old=Object.fromEntries([...$('#pipelineMigrations').querySelectorAll('select')].map(s=>[s.name,s.value]));$('#pipelineMigrations').innerHTML=removed.map(s=>`<label>Куда перенести задачи из «${esc(s.title)}» (${W.tasks.filter(t=>t.project_id===p.id&&t.stage_id===s.id).length})?<select name="migrate-${esc(s.id)}" required><option value="">Выберите этап</option>${pipeline.map(target=>option(target.id,target.title,old['migrate-'+s.id])).join('')}</select></label>`).join('');}
 $('#pipelineEditor').onclick=e=>{const button=e.target.closest('[data-pipe]');if(!button)return;syncPipeline();const index=pipeline.findIndex(s=>s.id===button.dataset.id),action=button.dataset.pipe;if(action==='remove'){const stage=pipeline.splice(index,1)[0];if(W.tasks.some(t=>t.project_id===p.id&&t.stage_id===stage.id))removed.push(stage);}else{const next=action==='up'?index-1:index+1;[pipeline[index],pipeline[next]]=[pipeline[next],pipeline[index]];}paint();};$('#addStage').onclick=()=>{syncPipeline();pipeline.push({id:'stage-'+crypto.randomUUID(),title:'Новый этап',kind:'active'});paint();};paint();}
function saveView(){showDialog('Сохранить выборку','<label>Название<input name="name" required placeholder="Например, мои задачи на неделю"></label>',async form=>{const name=formObject(form).name.trim();const list=[...(W.settings.saved_views||[])];if(list.some(v=>v.name===name))throw Error('Выборка с таким названием уже существует');list.push({name,filters:structuredClone({...prefs.taskFilters,...(prefs.section==='projects'&&prefs.projectId?{projects:[String(prefs.projectId)]}:{})}),sort:prefs.sort,group:prefs.group,view:prefs.taskView});await perform(()=>api.command('settings',{data:{saved_views:list}},prefs.demo),'Выборка сохранена');});}
function quick(key,allProjects=false,owner){let f={projects:prefs.overviewFilters.projects||[],assignees:prefs.overviewFilters.assignees||[],active:true};if(allProjects||prefs.section!=='overview')f={active:true};if(key==='mine')f.assignees=['me'];if(key==='unassigned')f.assignees=['none'];if(key==='undated')f.dues=['none'];if(key==='due-soon'||key==='due-later')f.dues=[key];if(key==='chart-owner')f.assignees=[owner];if(key==='blocked')f.blocked=true;if(key==='overdue')f.dues=['overdue'];if(key==='today'){f.dues=['today'];if(prefs.section==='overview'){const o=prefs.overviewFilters;f.windowFrom=o.horizon==='range'?(o.from||W.today):W.today;f.windowTo=o.horizon==='today'?W.today:o.horizon==='range'?(o.to||'9999'):addDays(W.today,6);}}if(key==='upcoming'){const o=prefs.overviewFilters;f.dues=['range'];f.from=[addDays(W.today,1),o.horizon==='range'?(o.from||W.today):W.today].sort().at(-1);f.to=o.horizon==='today'?W.today:o.horizon==='range'?(o.to||'9999'):addDays(W.today,6);}if(key==='missing'){f.missing=true;delete f.active;}
 // Missing responsibility and deadline is a union; use an explicit saved ID set in this quick view.
 if(key==='missing'){f={projects:f.projects,assignees:f.assignees,active:true,missing:true};}
 prefs.taskFilters=f;selected.clear();navigate('tasks');}
async function updateTask(task,changes,message='Задача обновлена'){await perform(()=>api.command('save_task',{id:task.id,revision:task.revision,data:{...task,...changes}},prefs.demo),message);}
function bulk(kind){const items=W.tasks.filter(t=>selected.has(t.id));if(!items.length)return;let content='';const groups=[...new Set(items.map(t=>t.project_id))];if(kind==='assignee')content=`<label>Назначить выбранным задачам<select name="assignee_id">${personOptions(null)}</select></label>`;if(kind==='due')content='<label>Новая дата (пусто — снять срок)<input name="due_date" type="date"></label><label>Время<input name="due_time" type="time"></label>';if(kind==='stage')content=groups.map(p=>`<label>${esc(project(p))}<select name="stage-${p??'none'}">${stages(W,p).map(s=>option(s.id,s.title)).join('')}</select></label>`).join('');showDialog('Изменить выбранные задачи',`<p>Будет изменено задач: ${items.length}. Действие можно отменить, пока задачи не изменились снова.</p>${content}`,async form=>{const v=formObject(form);const payload=items.map(t=>({id:t.id,revision:t.revision,data:{...t,...(kind==='assignee'?{assignee_id:v.assignee_id?Number(v.assignee_id):null}:kind==='due'?{due_date:v.due_date||null,due_time:v.due_date?(v.due_time||null):null}:{stage_id:v['stage-'+(t.project_id??'none')]})}}));const result=await perform(()=>api.command('batch_tasks',{items:payload},prefs.demo),'',true);selected.clear();lastUndo=result.batch_id;flash('Массовые изменения сохранены',async()=>{try{await perform(()=>api.command('undo_batch',{batch_id:lastUndo},prefs.demo),'Массовые изменения отменены');}catch{}});});}
function editSegment(index){const t=meetingData.transcript,s=t.segments[index];showDialog('Исправить текст',`<p class="muted">${time(s.start_ms)} — ${time(s.end_ms)}. Исходный текст модели останется в истории.</p><label>Текст<textarea name="text" required>${esc(s.text)}</textarea></label>`,async form=>{await api.request('segment/edit',{model_run_id:t.model_run_id,segment_id:s.id,text:formObject(form).text});await loadMeeting(prefs.meetingId);flash('Текст исправлен');});}
function assignSegment(index){const t=meetingData.transcript,s=t.segments[index];showDialog('Назначить говорящего',`<blockquote class="quote">${esc(s.text)}</blockquote><label>Участник<select name="person_id">${personOptions(s.person_id)}</select></label><label>Область изменения<select name="scope"><option value="segment">Только этот фрагмент</option>${s.speaker_id?'<option value="speaker">Все реплики этого голоса в этой версии встречи</option>':''}</select></label><p class="muted">Это ручное исправление. Ответственный за задачи не назначается по имени голоса автоматически.</p>`,async form=>{const v=formObject(form);await api.request('speaker/assign',{model_run_id:t.model_run_id,person_id:v.person_id?Number(v.person_id):null,...(v.scope==='speaker'?{speaker_id:s.speaker_id}:{segment_id:s.id})});await loadMeeting(prefs.meetingId);flash('Говорящий назначен');});}
function proposeSegment(index){const s=meetingData.transcript.segments[index],m=W.meetings.find(m=>m.id===prefs.meetingId);showDialog('Предложение из реплики',`<blockquote class="quote">${esc(s.text)}</blockquote><p class="muted">Изменение не применяется без отдельного подтверждения.</p><label>Тип предложения<select name="kind" id="proposalKind">${Object.entries(kinds).map(([k,v])=>option(k,v,'create_task')).join('')}</select></label><label>Формулировка<input name="title" required></label><label>Проект<select name="project_id">${projectOptions(m.project_id)}</select></label><div id="proposalExtra"></div>`,async form=>{const v=formObject(form);const target=W.tasks.find(t=>t.id===Number(v.task_id));const proposed={due_date:v.proposed_date||null,due_time:v.proposed_date?(v.proposed_time||null):null,assignee_id:v.proposed_person?Number(v.proposed_person):null,stage_id:v.proposed_stage||null};await perform(()=>api.command('propose',{data:{kind:v.kind,task_id:target?.id||null,title:v.title,description:'',project_id:target?.project_id||(v.project_id?Number(v.project_id):null),assignee_id:v.kind==='create_task'?proposed.assignee_id:null,due_date:v.kind==='create_task'?proposed.due_date:null,due_time:v.kind==='create_task'?proposed.due_time:null,proposed,source:{meeting_id:m.id,start_ms:s.start_ms,quote:s.text}}},prefs.demo),'Предложение отправлено на подтверждение');});
 const form=$('#modalForm');const paint=()=>{const kind=form.elements.kind.value;const changing=kind.startsWith('change_');$('#proposalExtra').innerHTML=changing?`<label>Существующая задача<select name="task_id" required><option value="">Выберите задачу</option>${W.tasks.map(t=>option(t.id,t.title)).join('')}</select></label>${kind==='change_due'?'<label>Предлагаемая дата<input name="proposed_date" type="date"></label><label>Время<input name="proposed_time" type="time"></label>':kind==='change_assignee'?`<label>Предлагаемый ответственный<select name="proposed_person">${personOptions(null)}</select></label>`:'<label>Предлагаемый этап<select name="proposed_stage" required><option value="">Сначала выберите задачу</option></select></label>'}`:(kind==='create_task'?`<label>Ответственный<select name="proposed_person">${personOptions(null)}</select></label><label>Дата срока<input name="proposed_date" type="date"></label><label>Время срока<input name="proposed_time" type="time"></label>`:'');if(changing)form.elements.task_id.onchange=()=>{const t=W.tasks.find(t=>t.id===Number(form.elements.task_id.value));if(t){form.elements.project_id.value=t.project_id||'';if(form.elements.proposed_stage)form.elements.proposed_stage.innerHTML=stages(W,t.project_id).map(stage=>option(stage.id,stage.title,t.stage_id)).join('');}};};$('#proposalKind').onchange=paint;paint();}
function reviewProposal(id){const proposal=W.proposals.find(p=>p.id===id);if(!proposal)return;const revisions=new Map(W.tasks.map(task=>[task.id,task.revision]));const target=W.tasks.find(t=>t.id===proposal.task_id);const base=proposal.kind==='create_task'?{...taskDefaults(W,proposal.project_id),title:proposal.title,description:proposal.description,assignee_id:proposal.assignee_id||null,due_date:proposal.due_date||null,due_time:proposal.due_time||null}:target?{...target,...proposal.proposed}:taskDefaults(W,proposal.project_id);const meeting=W.meetings.find(m=>m.id===proposal.source?.meeting_id);let content=`<details class="callout"><summary>Подробно о поручении</summary><p><strong>${esc(proposal.title)}</strong></p>${proposal.description?`<p class="notes-text">${esc(proposal.description)}</p>`:''}${meeting?`<p class="muted">${esc(meeting.title)} · ${time(proposal.source.start_ms||0)}</p>`:''}${proposal.source?.quote?`<blockquote class="quote">${esc(proposal.source.quote)}</blockquote>`:'<p class="muted">Исходная реплика недоступна.</p>'}${sourceButton(proposal.source)}</details>`+proposalClarification(proposal);if(proposal.kind==='decision')content+=`<label>Решение<textarea name="title" required>${esc(proposal.title)}</textarea></label><label>Проект<select name="project_id">${projectOptions(proposal.project_id)}</select></label>`;else if(proposal.kind==='create_task')content+=`${base.due_date?`<p><strong>Срок</strong> ${deadline(base)}</p>`:''}<label>Возможный дубликат<select name="existing_task_id">${option('','Создать новую задачу')}${W.tasks.map(t=>option(t.id,t.title)).join('')}</select></label><label class="check"><input type="checkbox" name="apply_due">Перенести указанный срок на выбранную существующую задачу</label>${taskFields(base,true)}`;else content+=`<p>Задача: ${esc(target?.title||'Не найдена')}</p><p>Проект: ${esc(project(target?.project_id))}</p><div class="before-after"><div>Сейчас: ${esc(target?proposalValue(proposal,target,false):'—')}</div><div>Предложено: ${esc(target?proposalValue(proposal,target,true):'—')}</div></div>${proposal.kind==='change_due'?`<label>Подтверждённая дата<input name="due_date" type="date" value="${esc(base.due_date)}"></label><label>Время<input name="due_time" type="time" value="${esc(base.due_time)}"></label>`:proposal.kind==='change_assignee'?`<label>Ответственный<select name="assignee_id">${personOptions(base.assignee_id)}</select></label>`:`<label>Статус<select name="stage_id">${stages(W,base.project_id).map(s=>option(s.id,s.title,base.stage_id)).join('')}</select></label>`}`;
 showDialog('Проверить и подтвердить',content,async form=>{const v=formObject(form);const data=proposal.kind==='decision'?{title:v.title,project_id:v.project_id?Number(v.project_id):null}:proposal.kind==='create_task'?readTask(form,base):{...base,...v,assignee_id:v.assignee_id?Number(v.assignee_id):null,due_date:v.due_date||null,due_time:v.due_date?(v.due_time||null):null};await perform(()=>api.command('review',{id,existing_task_id:proposal.kind==='create_task'?(v.existing_task_id?Number(v.existing_task_id):null):(v.existing_task_id?Number(v.existing_task_id):target?.id),task_revision:target?.revision??revisions.get(Number(v.existing_task_id)),apply_due:form.elements.apply_due?.checked===true,data},prefs.demo),'Предложение подтверждено');});const form=$('#modalForm');form.querySelector('[data-draft-project]')?.addEventListener('change',e=>{const pid=e.target.value?Number(e.target.value):null;form.querySelector('[name=stage_id]').innerHTML=stages(W,pid).map(s=>option(s.id,s.title)).join('');});form.querySelector('button[type=submit]').textContent='Подтвердить';}
async function processMeeting(id){const m=W.meetings.find(m=>m.id===id);if(m.processing?.status==='failed')await api.request('jobs/retry',{id:m.processing.id});else if(!['pending','running'].includes(m.processing?.status))await api.request('jobs',{meeting_id:id});await perform(()=>api.request('jobs/run',{meeting_id:id}),'Распознавание запущено');}
async function handleClick(event){const button=event.target.closest('button,a[data-source-meeting]');if(!button||button.disabled)return;
 if(button.dataset.overviewSchedule){
   prefs.overviewSchedule=button.dataset.overviewSchedule;
   savePrefs();renderAll();return;
 }
 if(button.dataset.calendarStep){
   const step=Number(button.dataset.calendarStep);
   const date=calendarDate||W.today;
   const period=prefs.calendarPeriod||'month';
   if(!step)calendarDate=null;
   else if(period==='day'||period==='week')calendarDate=addDays(date,step*(period==='week'?7:1));
   else{
     const first=new Date(date.slice(0,7)+'-01T00:00:00Z');
     first.setUTCMonth(first.getUTCMonth()+step*(period==='year'?12:1));
     calendarDate=first.toISOString().slice(0,10);
   }
   renderAll();return;
 }
 if(button.dataset.nav){if(button.hasAttribute('data-assistant-nav'))closeDialog();navigate(button.dataset.nav);return;}
 if(button.dataset.orbitPerson){selectedOrbitPerson=selectedOrbitPerson===button.dataset.orbitPerson?null:button.dataset.orbitPerson;meetingTab='summary';renderMeetingRelated();applyMeetingTab();renderMeetingCircleStatus();return;}
 if(button.dataset.action==='toggle-transcript-edit'){editTranscriptMode=!editTranscriptMode;matchIndex=0;const disclosure=$('#meetingTranscriptDisclosure');if(disclosure&&editTranscriptMode)disclosure.open=true;renderTranscript();if(editTranscriptMode)$('#meetingTranscript')?.focus();return;}
 if(button.dataset.meetingTab){meetingTab=button.dataset.meetingTab;applyMeetingTab();document.querySelector(`[data-meeting-tab="${meetingTab}"]`)?.focus();return;}
 if(button.dataset.action==='groq-analyze'){analyzeGroq();return;}
 if(button.dataset.action==='edit-notes'){editMeetingNotes();return;}
 if(button.dataset.action==='notes-history'){await notesHistory();return;}
 if(button.dataset.action==='assistant'){openAssistant();return;}
 if(button.dataset.action==='circle-people'){showDialog('Участники встречи',`<p>${(W.meetings.find(m=>m.id===prefs.meetingId)?.participants||[]).map(person).map(esc).join(', ')||'Участники пока не добавлены.'}</p><p class="muted">Список участников не является результатом идентификации голосов.</p><button data-close-modal>Закрыть</button>`,null);return;}
 if(button.dataset.task){openTask(Number(button.dataset.task));return;}
 if(button.dataset.project){navigate('projects',{project:Number(button.dataset.project)});return;}
 if(button.dataset.meeting){navigate('meetings',{meeting:Number(button.dataset.meeting)});return;}
 if(button.dataset.person){openPerson(Number(button.dataset.person));return;}
 if(button.dataset.projectTab){projectTab=button.dataset.projectTab;renderAll();return;}
 if(button.dataset.projectTaskFilter){projectTab='tasks';prefs.taskFilters=button.dataset.projectTaskFilter==='all'?{}:button.dataset.projectTaskFilter==='done'?{statuses:['kind:done']}:button.dataset.projectTaskFilter==='overdue'?{dues:['overdue'],active:true}:{active:true};savePrefs();renderAll();return;}
 if(button.dataset.taskView){prefs.taskView=button.dataset.taskView;savePrefs();renderAll();return;}
 if(button.dataset.projectView){prefs.projectView=button.dataset.projectView;savePrefs();renderAll();return;}
 if(button.dataset.quick){quick(button.dataset.quick,button.hasAttribute('data-chart-scope'),button.dataset.chartOwner);return;}
 if(button.dataset.bulk){bulk(button.dataset.bulk);return;}
 if(button.dataset.savedView){const v=W.settings.saved_views[Number(button.dataset.savedView)];prefs.taskFilters=structuredClone(v.filters);prefs.sort=v.sort;prefs.group=v.group;prefs.taskView=v.view;savePrefs();renderAll();return;}
 if(button.dataset.deleteView){const index=Number(button.dataset.deleteView);await perform(()=>api.command('settings',{data:{saved_views:W.settings.saved_views.filter((_,i)=>i!==index)}},prefs.demo),'Выборка удалена');return;}
 if(button.dataset.archiveProject){
  const p=W.projects.find(p=>p.id===Number(button.dataset.archiveProject));
  if(!p)return;
  const archived=!p.archived;
  showDialog(archived?'Переместить проект в архив?':'Восстановить проект?',`<p><strong>${esc(p.title)}</strong></p><p>${archived?'Проект переместится в раздел «Архив». Задачи, совещания и решения сохранятся.':'Проект вернётся в список рабочих проектов.'}</p>`,async()=>{
   await perform(()=>api.command('archive_project',{id:p.id,revision:p.revision,archived},prefs.demo),archived?'Проект в архиве':'Проект восстановлен');
  });
  return;
 }
 if(button.dataset.editProject){editProject(Number(button.dataset.editProject));return;}
 if(button.dataset.record){if(prefs.demo){error('Запись недоступна в демонстрационном режиме');return;}if(['start','continue'].includes(button.dataset.record)&&!confirm(button.dataset.record==='continue'?'Продолжить запись в этой встрече? Прежнее аудио сохранится. Участники предупреждены?':'Запись микрофона будет начата явно. Участники предупреждены?'))return;const seconds=Math.min(7200,Math.max(5,Number($('#recordLimit')?.value||60)));button.disabled=true;try{await api.request('recording/'+button.dataset.record,{meeting_id:Number(button.dataset.id),seconds,processing_mode:$('#meetingProcessingMode')?.value??H.speech.settings?.processing_mode??'post',device_uid:$('#meetingMicrophone')?.value??H.microphone?.selected?.uid??''});await refresh(false);renderMeetingControls();flash(button.dataset.record==='continue'?'Продолжаем встречу':button.dataset.record==='start'?'Запускаем микрофон':button.dataset.record==='stop'?'Завершаем и сохраняем запись':'Состояние записи изменено');}finally{button.disabled=false;}return;}
 if(button.dataset.seek){seekAudio(Number(button.dataset.seek));return;}
 if(button.dataset.editSegment){editSegment(Number(button.dataset.editSegment));return;}
 if(button.dataset.assignVoiceCluster){assignVoiceCluster(button.dataset.assignVoiceCluster);return;}
 if(button.dataset.enrollVoiceCluster){const speaker=button.dataset.enrollVoiceCluster,manual=(meetingData.transcript.speaker_assignments||[]).find(a=>a.speaker_id===speaker);await enrollVoiceCluster(speaker,manual?.person_id);return;}
 if(button.dataset.confirmVoiceCluster){confirmVoiceCandidate((meetingData.transcript.voice_matches||[]).find(v=>v.speaker_id===button.dataset.confirmVoiceCluster));return;}
 if(button.dataset.enrollSpeaker){await enrollSpeaker(Number(button.dataset.enrollSpeaker));return;}
 if(button.dataset.confirmVoice){confirmVoice(Number(button.dataset.confirmVoice));return;}
 if(button.dataset.rejectVoice){const t=meetingData.transcript,s=t.segments[Number(button.dataset.rejectVoice)];await api.request('speaker/assign',{model_run_id:t.model_run_id,speaker_id:s.speaker_id,person_id:null});await loadMeeting(prefs.meetingId);flash('Говорящий оставлен неизвестным вручную');return;}
 if(button.dataset.retryVoiceMatch){await api.request('voice/match/retry',{id:Number(button.dataset.retryVoiceMatch)});await refresh(false);renderVoiceMatchingControls();return;}
 if(button.dataset.assignSegment){assignSegment(Number(button.dataset.assignSegment));return;}
 if(button.dataset.proposeSegment){proposeSegment(Number(button.dataset.proposeSegment));return;}
 if(button.dataset.review){reviewProposal(Number(button.dataset.review));return;}
 if(button.dataset.reject){await perform(()=>api.command('review',{id:Number(button.dataset.reject),reject:true},prefs.demo),'Предложение отклонено');return;}
 if(button.dataset.sourceMeeting){event.preventDefault();const mid=Number(button.dataset.sourceMeeting),ms=Number(button.dataset.sourceMs);await guard(async()=>{closeInspector();closeDialog();navigate('meetings',{meeting:mid});await loadMeeting(mid);meetingTab='transcript';applyMeetingTab();const segment=[...document.querySelectorAll('.segment')].find(s=>Number(s.dataset.start)<=ms&&Number(s.dataset.end)>ms);segment?.scrollIntoView({block:'center'});segment?.classList.add('current');if(meetingData.recordings.length)seekAudio(ms);});return;}
 if(button.dataset.retryJob){await api.request('jobs/retry',{id:Number(button.dataset.retryJob)});await perform(()=>api.request('jobs/run',{meeting_id:Number(button.dataset.id)}),'Повторная обработка запущена');return;}
 if(button.dataset.runJob){await perform(()=>api.request('jobs/run',{meeting_id:Number(button.dataset.runJob)}),'Обработка запущена');return;}
 if(button.dataset.recoverJob){if(confirm('Подтвердите, что прежние процессы распознавания остановлены. Running-задание будет переведено в состояние ошибки для повторного запуска.'))await perform(()=>api.request('jobs/recover',{id:Number(button.dataset.recoverJob),confirmed_stopped:true}),'Задание восстановлено');return;}
 switch(button.dataset.action){
  case 'new-task':openTask();break;case 'new-person':newPerson();break;case 'new-project':editProject();break;case 'new-meeting':await guard(()=>{closeInspector();newMeeting();});break;case 'edit-meeting':newMeeting(true);break;
  case 'advanced-filters':prefs.advanced=!prefs.advanced;savePrefs();renderAll();break;case 'reset-filters':prefs.taskFilters={};selected.clear();savePrefs();renderAll();break;case 'save-view':saveView();break;case 'clear-selection':selected.clear();renderAll();break;
  case 'cancel-speech':await perform(()=>api.request('jobs/cancel',{meeting_id:prefs.meetingId}),'Распознавание прервано');break;
  case 'process-meeting':await processMeeting(prefs.meetingId);break;
  case 'match-voices':await api.request('voice/match',{model_run_id:meetingData.transcript.model_run_id});await refresh(false);renderVoiceMatchingControls();flash('Сопоставление голосов добавлено в очередь');break;
  case 'recover-voice-matching':if(confirm('Прежние голосовые обработчики завершены?')){await perform(()=>api.request('voice/recover',{confirmed_stopped:true}),'Голосовая очередь восстановлена');}break;
  case 'recover-live':if(confirm('Прежние процессы Live-распознавания остановлены? Прерванные задания будут отмечены ошибкой. Аудио и предварительный текст сохранятся.')){await api.request('live/recover',{meeting_id:prefs.meetingId,confirmed_stopped:true});await loadMeeting(prefs.meetingId);flash('Live-очередь восстановлена. Можно запустить полную обработку.');}break;
  case 'recover-meeting':if(confirm('Прежний процесс микрофона остановлен? Будут восстановлены завершённые фрагменты, незавершённый WAV автоматически не ремонтируется.')){const recovered=await perform(()=>api.request('recover',{meeting_id:prefs.meetingId,confirmed_stopped:true}),'',false);flash(recovered.recovered?'Сохранённые фрагменты проверены и доступны':'Завершённых фрагментов для восстановления не найдено');await loadMeeting(prefs.meetingId);renderAll();}break;
  case 'next-match':case 'previous-match':{const matches=[...document.querySelectorAll('.segment.match')];if(matches.length){matchIndex=(matchIndex+(button.dataset.action==='next-match'?1:-1)+matches.length)%matches.length;matches[matchIndex].scrollIntoView({block:'center'});matches.forEach(s=>s.classList.remove('current'));matches[matchIndex].classList.add('current');autoFollow=false;}break;}
  case 'follow-transcript':{const disclosure=$('#meetingTranscriptDisclosure');if(disclosure&&!disclosure.open){disclosure.open=true;renderTranscript();}autoFollow=true;const player=$('#player'),sources=mediaSources(),position=(sources[Number($('#audioTrack')?.value||0)]?.start||0)+(player?.currentTime||0)*1000;const segments=[...document.querySelectorAll('.segment[data-start]')];const target=segments.find(s=>Number(s.dataset.start)<=position&&Number(s.dataset.end)>position)||segments.find(s=>Number(s.dataset.start)>=position)||segments.at(-1);target?.scrollIntoView({block:'nearest'});break;}
  case 'demo-mode':toggleDemo(!prefs.demo);break;
 }
}
function bindView(){
 const calendarPeriod=$('#calendarPeriod');
 if(calendarPeriod)calendarPeriod.onchange=()=>{
   prefs.calendarPeriod=calendarPeriod.value;
   savePrefs();
   renderAll();
 };
 const matchingForm=$('#voiceMatchingSettingsForm');if(matchingForm)matchingForm.onsubmit=async e=>{e.preventDefault();try{await perform(()=>api.request('voice/matching/settings',{enabled:matchingForm.elements.enabled.checked,threshold:Number(matchingForm.elements.threshold.value),margin:Number(matchingForm.elements.margin.value)}),'Настройки сопоставления сохранены');}catch{}};

 const micForm=$('#microphoneForm');if(micForm){micForm.onsubmit=async e=>{e.preventDefault();try{await perform(()=>api.request('devices/select',{uid:micForm.elements.uid.value}),'Микрофон сохранён');}catch{}};$('#refreshMicrophones').onclick=async()=>{try{const result=await api.request('devices');H.microphone.devices=result.devices;renderAll();}catch(e){error(e.message);}};$('#testMicrophone').onclick=async()=>{try{await api.request('devices/test',{uid:micForm.elements.uid.value,seconds:5});await refresh(false);renderMicrophoneTest();}catch(e){error(e.message);}};renderMicrophoneTest();}

 const filter=(selector,key,group='taskFilters',array=false)=>{const element=$(selector);if(!element)return;element.onchange=()=>{const value=element.type==='checkbox'?element.checked:element.value;prefs[group]={...prefs[group],[key]:array?(value?[value]:[]):value};selected.clear();savePrefs();renderAll();};if(element.type==='search')element.oninput=()=>{clearTimeout(element.searchTimer);element.searchTimer=setTimeout(()=>element.onchange(),220);};};
 filter('#taskSearch','q');filter('#taskProject','projects','taskFilters',true);filter('#taskAssignee','assignees','taskFilters',true);filter('#taskFrom','from');filter('#taskTo','to');filter('#taskSource','source');filter('#taskBlocked','blocked');filter('#taskActive','active');
 filter('#overviewAssignee','assignees','overviewFilters',true);filter('#overviewProject','projects','overviewFilters',true);filter('#overviewHorizon','horizon','overviewFilters');filter('#overviewFrom','from','overviewFilters');filter('#overviewTo','to','overviewFilters');
 const archiveFilter=$('#projectArchiveFilter');if(archiveFilter)archiveFilter.onchange=()=>{prefs.projectFilters.archived=archiveFilter.value==='archived';renderAll();};
 filter('#projectSearch','q','projectFilters');filter('#projectStatus','status','projectFilters');filter('#projectOwner','owner','projectFilters');
 filter('#peopleSearch','q','peopleFilters');
 filter('#peopleDepartment','department','peopleFilters');
 filter('#peopleOrganization','organization','peopleFilters');
 filter('#peopleProject','project','peopleFilters');
 const clearPeopleFilters=$('#clearPeopleFilters');
 if(clearPeopleFilters)clearPeopleFilters.onclick=()=>{prefs.peopleFilters={};savePrefs();renderAll();};
 filter('#meetingSearch','q','meetingFilters');filter('#meetingProject','project','meetingFilters');filter('#meetingPerson','person','meetingFilters');filter('#meetingStatus','status','meetingFilters');filter('#meetingFrom','from','meetingFilters');filter('#meetingTo','to','meetingFilters');
 for(const [selector,key] of [['#taskSort','sort'],['#taskGroup','group']]){const element=$(selector);if(element)element.onchange=()=>{prefs[key]=element.value;savePrefs();renderAll();};}
 for(const input of document.querySelectorAll('[data-multi-filter]'))input.onchange=()=>{const key=input.dataset.multiFilter;const values=new Set(prefs.taskFilters[key]||[]);input.checked?values.add(input.value):values.delete(input.value);prefs.taskFilters[key]=[...values];selected.clear();savePrefs();renderAll();};
 for(const box of document.querySelectorAll('[data-select-task]'))box.onchange=()=>{const id=Number(box.dataset.selectTask);box.checked?selected.add(id):selected.delete(id);renderAll();};
 for(const box of document.querySelectorAll('[data-select-group]')){const ids=box.dataset.selectGroup.split(',').filter(Boolean).map(Number);box.checked=ids.length>0&&ids.every(id=>selected.has(id));box.indeterminate=!box.checked&&ids.some(id=>selected.has(id));box.onchange=()=>{for(const id of ids)box.checked?selected.add(id):selected.delete(id);renderAll();};}
 for(const select of document.querySelectorAll('[data-move-task]'))select.onchange=()=>{const task=W.tasks.find(t=>t.id===Number(select.dataset.moveTask));updateTask(task,{stage_id:select.value}).catch(()=>{});};
 for(const card of document.querySelectorAll('[data-drag-task]'))card.ondragstart=e=>e.dataTransfer.setData('text/plain',card.dataset.dragTask);
 for(const column of document.querySelectorAll('[data-drop-stage]')){column.ondragover=e=>{e.preventDefault();column.classList.add('drag-over');};column.ondragleave=()=>column.classList.remove('drag-over');column.ondrop=async e=>{e.preventDefault();column.classList.remove('drag-over');const task=W.tasks.find(t=>t.id===Number(e.dataTransfer.getData('text/plain')));if(!task)return;if(String(task.project_id??'none')!==column.dataset.dropProject){error('Между проектами задачи переносятся через карточку, с явным выбором этапа.');return;}try{await updateTask(task,{stage_id:column.dataset.dropStage});}catch{}};}
 const upload=$('#audioImport');if(upload)upload.onchange=async()=>{const file=upload.files[0];if(!file)return;upload.disabled=true;flash('Импортируем аудио…');try{await perform(()=>api.importAudio(prefs.meetingId,file),'Аудио сохранено',false);await loadMeeting(prefs.meetingId);renderAll();}catch{upload.disabled=false;}};
 const disclosure=$('#meetingTranscriptDisclosure');
 if(disclosure){
  const meetingId=prefs.meetingId;
  disclosure.ontoggle=()=>{
   if(disclosure.open){expandedMeetingTranscripts.add(meetingId);renderTranscript();}
   else expandedMeetingTranscripts.delete(meetingId);
  };
 }
 const search=$('#transcriptSearch');if(search)search.oninput=()=>{transcriptQuery=search.value;matchIndex=0;autoFollow=false;if(disclosure&&transcriptQuery.trim())disclosure.open=true;renderTranscript();};
 const groqForm=$('#groqSettingsForm');if(groqForm)groqForm.onsubmit=async e=>{e.preventDefault();const submit=groqForm.querySelector('[type=submit]');submit.disabled=true;try{await api.request('groq/settings',{model:groqForm.elements.model.value,api_key:groqForm.elements.api_key.value,persist:groqForm.elements.persist.checked,clear_key:groqForm.elements.clear_key.checked,automatic:groqForm.elements.automatic.checked});groqForm.elements.api_key.value='';await refresh(false);renderAll();flash('Настройки Groq приняты. Статус сохранения ключа показан ниже.');}catch(err){error(err.message);}finally{submit.disabled=false;}};
 const speechForm=$('#speechSettingsForm');if(speechForm){$('#localModelSelect').onchange=e=>{$('#localModelPath').value=e.target.value;};$('#cloudPreset').onchange=e=>{if(e.target.value==='openai'){speechForm.elements.url.value='https://api.openai.com/v1/audio/transcriptions';speechForm.elements.model.value='gpt-transcribe';speechForm.elements.format.value='json';}};speechForm.onsubmit=async e=>{e.preventDefault();const data={...formObject(speechForm),clear_key:speechForm.elements.clear_key.checked};try{await api.request('speech/settings',data);speechForm.elements.api_key.value='';await refresh(false);renderAll();flash('Модель сохранена');}catch(err){error(err.message);}};}
 const form=$('#settingsForm');if(form)form.onsubmit=async e=>{e.preventDefault();const v=formObject(form);const data={timezone:v.timezone,theme:v.theme,font_size:Number(v.font_size),auto_process:form.elements.auto_process.checked,[prefs.demo?'demo_me_id':'me_id']:v.me_id?Number(v.me_id):null};try{await perform(()=>api.command('settings',{data},prefs.demo),'Настройки сохранены');}catch{}};
}
document.addEventListener('click',event=>handleClick(event).catch(e=>error(e.message)));
window.addEventListener('beforeunload',event=>{if(dirty||H?.recording.active){event.preventDefault();event.returnValue='';}});
window.addEventListener('popstate',()=>{const [section,raw]=location.hash.slice(1).split('/');if(sections[section])navigate(section,{meeting:section==='meetings'&&raw?Number(raw):null,project:section==='projects'&&raw?Number(raw):null});});
async function pollCircleActivity(){
 const active=H?.recording.active;
 try{
  if(!document.hidden&&active?.state==='recording'&&active.meeting_id===prefs.meetingId&&$('#circleSpeaker')){
   const activity=await api.request('recording/activity');
   if(H.recording.active?.session_id===active.session_id&&H.recording.active.state==='recording'&&prefs.meetingId===active.meeting_id){
    if(activity.active?.session_id===active.session_id)renderMeetingCircleStatus(activity);
    else document.querySelectorAll('.orbit-person.is-candidate').forEach(el=>el.classList.remove('is-candidate'));
   }
  }
 }catch{
  document.querySelectorAll('.orbit-person.is-candidate').forEach(el=>el.classList.remove('is-candidate'));
 }finally{setTimeout(pollCircleActivity,200);}
}
async function poll(){try{await refresh(true);}catch(e){error('Связь с локальным сервером потеряна. Запись может продолжаться в отдельном процессе. '+e.message);}finally{setTimeout(poll,1000);}}
async function boot(){setupNavigation();try{await refresh(false);if(!W.settings.initialized){const timezone=Intl.DateTimeFormat().resolvedOptions().timeZone||'Europe/Moscow';await api.command('settings',{data:{timezone,initialized:true}});await refresh(false);}if(!sections[prefs.section])prefs.section='overview';renderAll();poll();pollCircleActivity();}catch(e){error(e.message);$('#main').innerHTML='<div class="empty">Не удалось загрузить данные. Проверьте, что локальный сервер работает, затем обновите страницу.</div>';}}
boot();

document.addEventListener('keydown',e=>{if(!e.target.matches('[data-meeting-tab][role=tab]')||!['ArrowLeft','ArrowRight','Home','End'].includes(e.key))return;e.preventDefault();const keys=[...document.querySelectorAll('.meeting-tabs [role=tab]')].map(tab=>tab.dataset.meetingTab),index=keys.indexOf(meetingTab);meetingTab=e.key==='Home'?keys[0]:e.key==='End'?keys.at(-1):keys[(index+(e.key==='ArrowRight'?1:keys.length-1))%keys.length];applyMeetingTab();document.querySelector(`[role=tab][data-meeting-tab="${meetingTab}"]`)?.focus();});

function manualNotesView(){const n=meetingData.manual_notes||{};return `<section class="manual-notes"><h3>Резюме</h3>${n.summary?`<p class="notes-text">${esc(n.summary)}</p>`:empty('Ручное резюме ещё не добавлено.')}<h3>Открытые вопросы</h3>${n.open_questions?`<p class="notes-text">${esc(n.open_questions)}</p>`:empty('Открытые вопросы не записаны.')}${n.revision?`<p class="muted">${esc(n.author_name||'Локальный пользователь')} · локальное рабочее пространство · ${stamp(n.updated_at)} · версия ${n.revision}</p><button class="link-button" data-action="notes-history">История итогов</button>`:''}</section>`;}
function editMeetingNotes(){const id=prefs.meetingId,n=structuredClone(meetingData.manual_notes||{revision:0,summary:'',open_questions:''});showDialog('Ручные итоги встречи',`<p class="muted">Итоги хранятся независимо от транскрипта. Поручения и решения подтверждаются отдельно.</p><label>Резюме<textarea name="summary" maxlength="20000" rows="6">${esc(n.summary)}</textarea></label><label>Открытые вопросы<textarea name="open_questions" maxlength="10000" rows="4">${esc(n.open_questions)}</textarea></label><p class="muted">Версия ${n.revision}. При конфликте введённый текст останется в этой форме.</p>`,async form=>{const v=formObject(form);await api.command('save_meeting_notes',{meeting_id:id,revision:n.revision,summary:v.summary,open_questions:v.open_questions},prefs.demo);await refresh(false);await loadMeeting(id);flash('Ручные итоги сохранены');});}
async function notesHistory(){try{const rows=await api.command('meeting_notes_history',{meeting_id:prefs.meetingId},prefs.demo);showDialog('История итогов',`${rows.map(h=>`<article class="card"><h3>Версия ${h.after.revision}</h3><small>${esc(h.after.author_name)} · локальное рабочее пространство · ${stamp(h.created_at)}</small><h3 style="margin-top:16px">Резюме</h3><p class="notes-text">${esc(h.after.summary||'Пусто')}</p><h3>Открытые вопросы</h3><p class="notes-text">${esc(h.after.open_questions||'Пусто')}</p></article>`).join('')||empty('История пока пуста.')}<button data-close-modal>Закрыть</button>`,null);}catch(e){error(e.message);}}
const voicePhrases=[
 'Сегодня мы обсуждаем планы и договариваемся о следующих шагах.',
 'Я могу говорить спокойно, чуть быстрее и с разной интонацией.',
 'После встречи мы проверим задачи, сроки и важные решения.'
];
let voicePhraseIndex=0,voiceCaptureRequestBusy=false;
function currentVoiceDraft(id){const d=H?.voice_capture?.draft;return d?.person_id===id?d:null;}
function voiceCaptureError(message){const box=$('#modalError');if(box){box.textContent=message;box.hidden=false;}}
async function voiceCaptureAction(fn){if(voiceCaptureRequestBusy)return;voiceCaptureRequestBusy=true;try{const operation=fn();renderVoiceCaptureStatus();await operation;$('#modalError').hidden=true;await refresh(false);renderVoicePersonStatus();}catch(e){voiceCaptureError(e.message);}finally{voiceCaptureRequestBusy=false;renderVoiceCaptureStatus();}}
async function closeVoicePerson(id,after=closeDialog){if(voiceCaptureRequestBusy){voiceCaptureError('Дождитесь ответа микрофона.');return;}await voiceCaptureAction(async()=>{const d=currentVoiceDraft(id);if(d)await api.request('voice/capture/cancel',{draft_id:d.id,person_id:id});});if(!$('#modalError')?.hidden)return;after();if(prefs.section==='people'&&!$('#modal').open)renderAll();}
function renderVoiceCaptureStatus(){
 const root=$('#voiceCaptureStatus');if(!root)return;const id=Number(root.dataset.person),d=currentVoiceDraft(id),other=H.voice_capture?.draft&&!d;
 const blocked=!!H.recording.active||H.speech.running||H.voice?.running||H.live?.running||other||voiceCaptureRequestBusy;
 if(d?.phrase_index!=null)voicePhraseIndex=d.phrase_index;
 const key=JSON.stringify([d?.id,d?.state,d?.phrase_index,blocked,H.voice?.configured,H.recording.available,H.voice_capture?.last]);
 if(root.dataset.key!==key){root.dataset.key=key;const last=H.voice_capture?.last;
  if(!d)root.innerHTML=`${other?'<p class="callout warning">Сначала завершите процедуру голосового образца другого участника.</p>':''}${last?.person_id===id&&last.error?`<p class="callout warning">${esc(last.error)}</p>`:''}<button class="primary" id="voiceRecordStart" ${blocked||!H.voice?.configured||!H.recording.available?'disabled':''}>Записать голос с микрофона</button>${blocked&&!other?'<p class="muted">Дождитесь окончания текущей записи или обработки.</p>':''}<p class="muted">Прочитайте каждую фразу обычным голосом. Пауза примерно в полторы секунды переключит на следующую.</p>`;
  else if(['starting','recording','stopping','preparing'].includes(d.state))root.innerHTML=`<p role="status" class="voice-record-state">${esc(({starting:'Подключаем микрофон…',recording:'Запись образца',stopping:'Сохраняем запись…',preparing:'Проверяем качество звука…'})[d.state])} <strong id="voiceCaptureClock"></strong></p><progress id="voiceCaptureProgress" value="0" max="45000" aria-label="Время записи"></progress><p class="muted">${esc(d.device?.name||'Выбранный микрофон')}</p><meter id="voiceCaptureLevel" min="0" max="1" value="0" aria-label="Уровень микрофона при записи образца"></meter><ol class="voice-phrases">${(d.phrases??voicePhrases).map((p,i)=>`<li data-voice-phrase="${i}" class="${i===voicePhraseIndex?'current':''}">${esc(p)}</li>`).join('')}</ol>${d.phrase_index>=3?'<p role="status">Все фразы прочитаны.</p>':''}<div class="row-actions"><button id="voiceNextPhrase" ${voiceCaptureRequestBusy||d.state!=='recording'||voicePhraseIndex>=2?'disabled':''}>${voicePhraseIndex>=2?'Последняя фраза':'Следующая фраза'}</button><button class="primary" id="voiceRecordStop" ${voiceCaptureRequestBusy||!['starting','recording'].includes(d.state)?'disabled':''}>Завершить и прослушать</button><button id="voiceRecordCancel" ${voiceCaptureRequestBusy?'disabled':''}>Отменить запись</button></div>`;
  else root.innerHTML=`${d.error?`<p role="alert" class="callout warning">${esc(d.error)}</p>`:''}${['ready','rejected'].includes(d.state)?`<h3>Прослушайте образец</h3><audio controls preload="metadata" aria-label="Записанный образец голоса" src="/api/voice/capture/audio/${encodeURIComponent(d.id)}"></audio><p class="muted">${d.quality?'Длительность: '+Number(d.quality.duration_seconds).toFixed(1)+' с. Техническая проверка пройдена.':'Запись не прошла техническую проверку.'} ${esc(d.device?.name||'')}</p>`:''}${d.state==='ready'?'<label class="check"><input type="checkbox" id="voiceRecordedSolo">Я прослушал образец: в нём говорит только этот участник.</label><button class="primary" id="voiceRecordAccept">Сохранить голосовой профиль</button>':''}<div class="row-actions"><button id="voiceRecordRetake" ${blocked?'disabled':''}>Записать заново</button><button id="voiceRecordCancel" ${voiceCaptureRequestBusy?'disabled':''}>Удалить временный образец</button></div>`;
  const consent=()=>$('#voiceRecordConsent')?.checked===true;
  const start=async()=>{if(!consent())throw Error('Подтвердите согласие участника перед записью.');voicePhraseIndex=0;await api.request('voice/capture/start',{person_id:id,device_uid:$('#voiceRecordDevice').value,consent:true});};
  $('#voiceRecordStart')?.addEventListener('click',()=>voiceCaptureAction(start));
  $('#voiceRecordStop')?.addEventListener('click',()=>voiceCaptureAction(()=>api.request('voice/capture/stop',{person_id:id,draft_id:d.id})));
  $('#voiceRecordCancel')?.addEventListener('click',()=>voiceCaptureAction(()=>api.request('voice/capture/cancel',{person_id:id,draft_id:d.id})));
  $('#voiceRecordRetake')?.addEventListener('click',()=>voiceCaptureAction(async()=>{if(!consent())throw Error('Подтвердите согласие участника перед новой записью.');await api.request('voice/capture/cancel',{person_id:id,draft_id:d.id});await start();}));
  $('#voiceRecordAccept')?.addEventListener('click',()=>voiceCaptureAction(async()=>{if(!consent()||!$('#voiceRecordedSolo').checked)throw Error('Нужны согласие участника и подтверждение после прослушивания.');await api.request('voice/capture/accept',{person_id:id,draft_id:d.id,consent:true,single_speaker:true});$('#voiceRecordConsent').checked=false;flash('Образец принят. Создаём профиль локально…');}));
  $('#voiceNextPhrase')?.addEventListener('click',()=>{if(d.phrase_index!=null){void voiceCaptureAction(()=>api.request('voice/capture/next',{draft_id:d.id,person_id:id,phrase_index:d.phrase_index}));return;}voicePhraseIndex=Math.min(2,voicePhraseIndex+1);document.querySelectorAll('[data-voice-phrase]').forEach(e=>e.classList.toggle('current',Number(e.dataset.voicePhrase)===voicePhraseIndex));const b=$('#voiceNextPhrase');b.disabled=voicePhraseIndex>=2;b.textContent=voicePhraseIndex>=2?'Все фразы прочитаны':'Следующая фраза';});
 }
 const accept=$('#voiceRecordAccept');if(accept)accept.disabled=voiceCaptureRequestBusy;
 const clock=$('#voiceCaptureClock');if(clock&&d)clock.textContent=time(d.elapsed_ms||0)+' / 00:45';
 const progress=$('#voiceCaptureProgress');if(progress&&d){progress.max=(d.limit_seconds||45)*1000;progress.value=d.elapsed_ms||0;}
 const meter=$('#voiceCaptureLevel');if(meter&&d)meter.value=Math.min(1,(d.level||0)*4);
 const device=$('#voiceRecordDevice');if(device)device.disabled=!!d&&['starting','recording','stopping','preparing'].includes(d.state);
}

function groqSettings(){const g=H.groq||{};return `<section class="section" style="grid-column:1/-1"><h2>Резюме и задачи · Groq</h2><p>Анализирует текст встречи вручную или автоматически после распознавания. Задачи и решения требуют подтверждения.</p><form id="groqSettingsForm"><div class="form-grid"><label>Модель<select name="model">${(g.models||[]).map(m=>option(m,m==='openai/gpt-oss-120b'?'GPT OSS 120B · качество':'GPT OSS 20B · быстрее',g.model)).join('')}</select></label><label>API-ключ Groq<input name="api_key" type="password" autocomplete="new-password" placeholder="${g.has_key?'Ключ уже добавлен; оставьте поле пустым':'Вставьте ключ здесь'}"></label><label class="check wide"><input name="persist" type="checkbox" checked>Сохранить новый ключ в Связке ключей macOS</label><label class="check wide"><input name="clear_key" type="checkbox">Удалить ключ Groq</label><label class="check wide"><input name="automatic" type="checkbox" ${g.automatic?'checked':''}>Автоматически отправлять текст распознанных встреч в Groq для резюме и предложений задач</label><p class="muted wide">Без сохранения ключ действует до перезапуска сервера. В базу данных, экспорт и Git ключ не записывается. Отправляется только текст и участники выбранной встречи; аудио и голосовые профили остаются на Mac.</p></div><button class="primary" type="submit" ${g.busy?'disabled':''}>Сохранить Groq</button><p role="status">${g.busy?(g.operation==='analyze'?'Groq анализирует встречу…':'Операция со Связкой ключей…'):g.has_key?(g.storage==='keychain'?'Ключ в Связке ключей macOS':'Ключ действует в этой сессии'):'Ключ не добавлен'}</p>${g.error?`<p class="callout danger">${esc(g.error)}</p>`:''}</form></section>`;}
function groqSummary(){const a=meetingData.analysis,g=H.groq||{},saved=a?.saved,r=saved?.result,busy=a?.state==='running'||a?.state==='pending';return `<section class="section groq-summary"><div class="section-heading"><h3>Резюме Groq</h3><button class="primary" data-action="groq-analyze" ${prefs.demo||g.busy||meetingData.transcript?.needs_update||!meetingData.transcript?.segments?.length?'disabled':''}>${busy?'Анализируется…':saved?'Обновить резюме и задачи':'Составить резюме и задачи'}</button></div>${meetingData.transcript?.needs_update?'<p class="muted">Сначала обновите распознавание во вкладке «Протокол».</p>':''}${!g.has_key?'<p class="muted">Добавьте API-ключ в <button class="link-button" data-nav="settings">настройках Groq</button>.</p>':''}${busy?'<p role="status">Отправленный текст обрабатывается в Groq. Можно перейти в другой раздел.</p>':''}${a?.error?`<p class="callout danger">${esc(a.error)}</p>`:''}${a?.stale?'<p class="callout warning">Изменились текст встречи или правила анализа. Обновите резюме. Ранее созданные предложения сохраняют исходную цитату.</p>':''}${r?`<p class="notes-text">${esc(r.summary)}</p><small class="muted">${esc(saved.model)} · ${stamp(saved.created_at)} · проверьте выводы по транскрипту</small>${r.open_questions?.length?`<h4>Открытые вопросы</h4><ul>${r.open_questions.map(q=>`<li>${esc(q)}</li>`).join('')}</ul>`:''}<p>Предложено поручений: ${r.tasks.length}, решений: ${r.decisions.length}.</p>${!r.tasks.length?'<p class="callout">Модель не выделила поручений. Проверьте, сохранилось ли нужное действие в транскрипте. При необходимости исправьте текст или предложите задачу из реплики вручную. Слово «задача» не обязательно.</p>':''}<button data-meeting-tab="tasks">Проверить задачи и решения</button>`:!busy?'<p class="muted">После анализа здесь появятся резюме и открытые вопросы. Ручные заметки сохранятся отдельно.</p>':''}</section>`;}
function analyzeGroq(){if(!H.groq?.has_key){navigate('settings');return;}const mid=prefs.meetingId;const segments=meetingData.transcript?.segments||[];showDialog('Отправить текст встречи в Groq',`<p>Встреча: <strong>${esc(meetingData.meeting.title)}</strong></p><p>Модель: ${esc(H.groq.model)}. Реплик: ${segments.length}. Текст, названия и подтверждённые имена участников будут отправлены в облачный API Groq.</p><p>Аудио и голосовые профили остаются на Mac. Результат AI нужно проверить; задачи не будут созданы автоматически.</p><label class="check"><input name="consent" type="checkbox" required>Подтверждаю отправку текста этой встречи в Groq</label>`,async form=>{if(!form.elements.consent.checked)throw Error('Подтвердите отправку текста');const result=await api.request('groq/analyze',{meeting_id:mid,consent:true});await refresh(false);await loadMeeting(mid);flash(result.cached?'Актуальный анализ уже сохранён; повторной отправки нет':'Groq составляет резюме и предложения задач');});$('#modal button[type="submit"]').textContent='Отправить и проанализировать';}

function proposalClarification(p){return p.needs_clarification?`<div class="callout warning"><strong>Нужно уточнение</strong><p>${esc(p.clarification)}</p></div>`:'';}
