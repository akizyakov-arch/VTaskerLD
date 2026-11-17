// Service boundary: views do not own domain data or simulate successful persistence.
export class VTaskService{
 async request(path,body){const response=await fetch('/api/'+path,body===undefined?{}:{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});const value=await response.json();if(!response.ok)throw Error(value.error||'Не удалось выполнить действие');return value;}
 async enrollVoice(id,file){const response=await fetch('/api/voice/enroll?person_id='+id,{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Voice-Consent':'confirmed','X-Voice-Single-Speaker':'confirmed'},body:file});const value=await response.json();if(!response.ok)throw Error(value.error||'Не удалось загрузить голосовой образец');return value;}
 snapshot(demo=false){return this.request('workspace'+(demo?'?demo=1':''));}
 status(){return this.request('status');}
 command(op,data={},demo=false){return this.request('workspace/action',{op,demo,...data});}
 meeting(id){return this.request('meeting/'+id);}
 async importAudio(id,file){const response=await fetch('/api/import?meeting_id='+id,{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:file});const value=await response.json();if(!response.ok)throw Error(value.error||'Импорт не выполнен');return value;}
}
