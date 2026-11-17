# -*- coding: utf-8 -*-
"""Offline synthetic Groq fixture. Never contacts a service or touches Keychain."""
import json,sys,time
v=json.load(sys.stdin)
if v['mode']=='load_key':out={'key':'fixture_not_a_real_groq_key_12345'}
elif v['mode']=='analyze':
 time.sleep(1)
 sid=v['input']['segments'][0]['id']
 out={'summary':'Команда договорилась подготовить отчёт к следующей встрече.','open_questions':['Кто проверит готовый отчёт?'],'decisions':[{'text':'Подготовить отчёт к следующей встрече','source_segment_ids':[sid]}],'tasks':[{'title':'Подготовить отчёт','description':'Собрать итоги обсуждения в документ.','assignee_name':None,'due_date':None,'needs_clarification':True,'clarification':'Уточните, кто подготовит отчёт.','source_segment_ids':[sid]}]}
else:out={'saved':False,'storage':'session'}
print(json.dumps({'ok':True,'value':out},ensure_ascii=False))
