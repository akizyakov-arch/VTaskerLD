# -*- coding: utf-8 -*-
"""Offline provider contract tests: no credentials, Keychain writes or network."""
import importlib.util,json,unittest,urllib.error
import sqlite3
import tempfile
from unittest.mock import patch
from pathlib import Path
spec=importlib.util.spec_from_file_location('groq',Path(__file__).parents[1]/'scripts/groq-analyze.py');g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)
class Response:
 def __init__(self,value):self.value=value
 def __enter__(self):return self
 def __exit__(self,*args):pass
 def read(self,n):return json.dumps(self.value).encode()
class Provider(unittest.TestCase):
 def test_recap_reuses_specific_tasks_without_merging_other_work(self):
  segments = [
   {'id': 1, 'text': 'Решить со световиками, как вешать панели.'},
   {'id': 2, 'text': 'Что осталось решить?'},
   {'id': 3, 'text': 'Со световиками.'},
  ]
  detailed = {'title': 'Решить со световиками, как вешать панели', 'source_segment_ids': [1, 3]}
  recap = {'title': 'Решить вопрос со световиками', 'source_segment_ids': [3]}
  different_due = {**recap, 'due_date': '2026-12-07'}
  different_project = {**recap, 'project_id': 2}
  independent = {**recap, 'title': 'Решить вопрос с пожарной сигнализацией'}
  self.assertEqual(g.remove_recap_tasks(
      [detailed, recap, independent, different_due, different_project], segments),
      [detailed, independent, different_due, different_project])
  second_match = {**detailed, 'title': 'Решить со световиками, где поставить стойки'}
  self.assertEqual(g.remove_recap_tasks([detailed, second_match, recap], segments),
                   [detailed, second_match, recap])
  self.assertEqual(g.remove_recap_tasks([detailed, recap], segments[:1] + segments[2:]),
                   [detailed, recap])

 def test_industry_terms_are_optional_context_separate_from_the_prompt(self):
  result = {'summary':'Итоги','tasks':[],'decisions':[],'open_questions':[]}
  glossary = [{'title':'Лабораторные работы','prefixes':['пипет'],'phrases':['серия проб']}]
  with patch.object(g, 'meeting_topic_rules', return_value=glossary):
   with patch.object(g, 'request', return_value=result) as request:
    g.analyze({'input':{'segments':[{'id':1,'text':'Проверить пипетки'}]}})
    data = request.call_args.args[1]
    self.assertEqual(data['topic_glossary'], [{'topic':'Лабораторные работы','terms':['пипет']}])
    self.assertNotIn('Лабораторные работы', request.call_args.kwargs['system'])
    g.analyze({'input':{'segments':[{'id':1,'text':'Подготовить инструкцию'}]}})
    self.assertNotIn('topic_glossary', request.call_args.args[1])

 def test_local_fields_require_evidence_in_the_linked_segments(self):
  result = {'tasks':[
   {'source_segment_ids':[1], 'assignee_name':'Марина','due_date':'2026-12-07'},
   {'source_segment_ids':[2,3], 'assignee_name':'Марина','due_date':'2026-12-07'},
  ]}
  g.check_local_field_evidence(result, {'segments':[
   {'id':1,'text':'Подготовить инструкцию для администраторов.'},
   {'id':2,'text':'Инструкцию экскурсоводам поручаем Марине.'},
   {'id':3,'text':'Срок — до понедельника.'},
  ]})
  self.assertIsNone(result['tasks'][0]['assignee_name'])
  self.assertIsNone(result['tasks'][0]['due_date'])
  self.assertTrue(result['tasks'][0]['needs_clarification'])
  self.assertEqual(result['tasks'][1]['assignee_name'],'Марина')
  self.assertEqual(result['tasks'][1]['due_date'],'2026-12-07')

 def test_ollama_flags_bad_dates_without_discarding_other_tasks(self):
  result = {'tasks':[{'due_date':'2026-02-30','due_time':'18:00'},
                     {'due_date':'2026-12-01','due_time':'18:00'}]}
  g.normalize_local_deadlines(result)
  bad, good = result['tasks']
  self.assertIsNone(bad['due_date'])
  self.assertIsNone(bad['due_time'])
  self.assertTrue(bad['needs_clarification'])
  self.assertEqual(good['due_time'], '18:00')

 def test_ollama_uses_loopback_schema_and_no_api_key(self):
  class Opener:
   def open(self, req, timeout):
    self_test.assertEqual(req.full_url, 'http://127.0.0.1:11434/api/chat')
    self_test.assertIsNone(req.get_header('Authorization'))
    body = json.loads(req.data)
    self_test.assertEqual(body['format'], g.ASSISTANT_SCHEMA)
    self_test.assertEqual(body['keep_alive'], '5m')
    self_test.assertEqual(body['model'], 'qwen3:4b-instruct-2507-q4_K_M')
    return Response({'done':True,'done_reason':'stop','message':{'content':'{"action":"clarify"}'}})
  self_test = self
  with patch.object(g.urllib.request, 'build_opener', return_value=Opener()):
   out = g.request({'model':'ollama:qwen3:4b-instruct-2507-q4_K_M'}, {'text':'Привет'}, g.ASSISTANT_SCHEMA)
  self.assertEqual(out, {'action':'clarify'})

 def test_assistant_extracts_updates_without_sending_records(self):
  intent = dict.fromkeys(g.ASSISTANT_SCHEMA['properties'])
  intent.update(action='update_task', title='сетка', due_date='2026-12-01', assignee='Давид')
  text = 'Пусть Давид спросит про сетку к первому декабря'
  with patch.object(g, 'request', return_value=intent) as request:
   self.assertEqual(g.interpret({'text':text, 'has_project':True, 'today':'2026-11-20',
                                 'segments':['private'], 'project_tasks':['private']}), intent)
  request.assert_called_once()
  self.assertEqual(request.call_args.args[1], {
   'text':text, 'has_search':None, 'has_project':True, 'today':'2026-11-20'
  })
  self.assertEqual(request.call_args.args[4], 512)
  self.assertFalse(request.call_args.kwargs['allow_retry'])

 def test_assistant_followup_only_sends_relevant_date_and_cannot_create(self):
  intent = dict.fromkeys(g.TASK_UPDATE_SCHEMA['properties'])
  intent.update(action='update_task', due_date='2026-12-02')
  data = {'task_update_followup':True, 'text':'Да, только на второе',
          'today':'2026-11-20', 'prior_due_date':'2026-12-01', 'assignee':'private'}
  with patch.object(g, 'request', return_value=intent) as request:
   self.assertEqual(g.interpret(data), intent)
  self.assertEqual(request.call_args.args[1], {
   'text':data['text'], 'today':data['today'], 'prior_due_date':data['prior_due_date']
  })
  with patch.object(g, 'request', return_value={**intent, 'action':'create_task'}):
   with self.assertRaises(g.ProviderError):
    g.interpret(data)

 def test_assistant_rejects_creation_on_the_main_route(self):
  intent = dict.fromkeys(g.ASSISTANT_SCHEMA['properties'])
  intent.update(action='create_task', title='Новая задача')
  with patch.object(g, 'request', return_value=intent):
   with self.assertRaises(g.ProviderError):
    g.interpret({'text':'Создай новую задачу'})

 def test_strict_schema_and_secret_only_in_authorization(self):
  captured=[]
  class Opener:
   def open(self,req,timeout):
    captured.append(req);return Response({'choices':[{'finish_reason':'stop','message':{'content':'{"summary":"ok"}'}}]})
  with patch.object(g.urllib.request,'build_opener',return_value=Opener()):
   self.assertEqual(g.request({'key':'not-a-real-secret','model':'openai/gpt-oss-120b'},{'segments':[]}),{'summary':'ok'})
  req=captured[0];body=json.loads(req.data);self.assertTrue(body['response_format']['json_schema']['strict']);self.assertNotIn('not-a-real-secret',req.data.decode());self.assertEqual(req.full_url,g.ENDPOINT)
 def test_errors_never_echo_provider_body_or_secret(self):
  class Opener:
   def open(self,*args,**kwargs):raise urllib.error.HTTPError(g.ENDPOINT,401,'secret private transcript',{},None)
  with patch.object(g.urllib.request,'build_opener',return_value=Opener()):
   with self.assertRaises(g.ProviderError) as error:g.request({'key':'secret','model':'openai/gpt-oss-20b'},{})
  self.assertNotIn('secret',str(error.exception));self.assertIn('401',str(error.exception))
 def test_truncated_answers_are_not_saved(self):
  class Opener:
   def open(self,*args,**kwargs):return Response({'choices':[{'finish_reason':'length','message':{'content':'{"summary":"partial"}'}}]})
  with patch.object(g.urllib.request,'build_opener',return_value=Opener()):
   with self.assertRaises(g.ProviderError):g.request({'key':'fake','model':'openai/gpt-oss-20b'},{})
 def test_long_input_chunks_and_ignores_out_of_chunk_evidence(self):
  calls=[]
  def request(data,payload,schema=g.SCHEMA,**kwargs):
   calls.append(payload)
   if 'parts' in payload and isinstance(payload['parts'],list):return {'summary':'combined','open_questions':[]}
   return {'summary':'part','open_questions':[],'tasks':[{'title':'same','source_segment_ids':[0]}],'decisions':[]}
  with patch.object(g,'request',side_effect=request):r=g.analyze({'input':{'segments':[{'id':i,'text':'x'*30000} for i in range(3)]}})
  self.assertEqual(len(calls),4);self.assertEqual(r['summary'],'combined');self.assertEqual(len(r['tasks']),1)
 def test_ollama_automatic_analysis_keeps_short_protocol_together(self):
  model = 'ollama:qwen3:4b-instruct-2507-q4_K_M'
  result = {'summary':'Итоги', 'tasks':[], 'decisions':[], 'open_questions':[]}
  short = [{'id':i, 'text':'Согласовали стоимость и дату доставки.'} for i in range(94)]
  with patch.object(g, 'request', return_value=result) as request:
   g.analyze({'model':model, 'input':{'segments':short}, 'automatic':True})
   request.assert_called_once()
   self.assertEqual(request.call_args.args[1]['segments'], short)
   fields = request.call_args.kwargs['schema']['properties']['tasks']['items']['required']
   self.assertTrue({'assignee_name', 'due_date', 'source_segment_ids'}.issubset(fields))
   self.assertNotIn('material_ids', fields)
   self.assertIn('material_ids', g.SCHEMA['properties']['tasks']['items']['required'])

 def test_automatic_analysis_receives_scope_without_manual_project_records(self):
  snapshot = {
   'project_id': 1, 'analysis_projects': [{'id': 1, 'title': 'Тенты'}],
   'project_tasks': [{'id': 5, 'title': 'Купить ткань на шторы', 'project_id': 1}],
   'segments': [{'id': 1, 'text':'Перенести закупку ткани на шторы'}],
  }
  result = {'summary':'Итоги', 'tasks':[], 'decisions':[], 'open_questions':[]}
  with patch.object(g, 'request', return_value=result) as request:
   g.analyze({'model':'deepseek:deepseek-flash', 'input':snapshot, 'automatic':True})
   payload = request.call_args.args[1]
   self.assertEqual(payload['project_id'], 1)
   self.assertEqual(payload['analysis_projects'], snapshot['analysis_projects'])
   self.assertNotIn('project_tasks', payload)
   g.analyze({'model':'deepseek:deepseek-flash', 'input':snapshot})
   self.assertEqual(request.call_args.args[1]['project_tasks'], snapshot['project_tasks'])

 def test_completed_task_context_requires_explicit_reference_in_the_block(self):
  snapshot = {'project_tasks':[
   {'id':1, 'title':'Купить ткань на шторы', 'stage_kind':'done'},
   {'id':2, 'title':'Купить ткань на столы', 'stage_kind':'active'},
  ]}
  tasks, _, _ = g.relevant_context(snapshot, [{'text':'Купить ткань на шторы'}], [])
  self.assertEqual([task['id'] for task in tasks], [2])
  tasks, _, _ = g.relevant_context(snapshot, [{'text':'Вернёмся к задаче #1'}], [])
  self.assertEqual([task['id'] for task in tasks], [1])

 def test_ollama_automatic_analysis_still_splits_large_text(self):
  model = 'ollama:qwen3:4b-instruct-2507-q4_K_M'
  result = {'summary':'Итоги', 'tasks':[], 'decisions':[], 'open_questions':[]}
  result['protocol_title'] = 'План квартальной отчётности'
  segments = [{'id':i, 'text':'x'*30000} for i in range(3)]
  with patch.object(g, 'request', return_value=result) as request:
   analyzed = g.analyze({'model':model, 'input':{'segments':segments}, 'automatic':True})
   self.assertEqual(request.call_count, 4)
   self.assertEqual(analyzed['protocol_title'], result['protocol_title'])
 def test_empty_and_oversized_transcripts_do_not_call_provider(self):
  with patch.object(g,'request') as call:
   for segments in ([],[{'text':'x'*45001}]):
    with self.assertRaises(g.ProviderError):g.analyze({'input':{'segments':segments}})
   call.assert_not_called()
 def test_redirect_is_not_followed(self):
  # The production opener installs NoRedirect, ensuring credentials cannot be redirected.
  captured=[]
  def opener(handler):
   captured.append(handler)
   class O:
    def open(self,*args,**kwargs):raise urllib.error.HTTPError(g.ENDPOINT,302,'redirect',{},None)
   return O()
  with patch.object(g.urllib.request,'build_opener',side_effect=opener):
   with self.assertRaises(g.ProviderError):g.request({'key':'fake','model':'openai/gpt-oss-20b'},{})
  self.assertIsNone(captured[0].redirect_request(None,None,None,None,None,None))

class AIBudgetTests(unittest.TestCase):
 def setUp(self):
  temp = tempfile.TemporaryDirectory()
  self.addCleanup(temp.cleanup)
  self.db = str(Path(temp.name) / 'usage.sqlite')
  with sqlite3.connect(self.db) as connection:
   connection.execute('CREATE TABLE workspace_settings(key TEXT PRIMARY KEY, data_json TEXT NOT NULL)')
   migration = Path(__file__).parents[1] / 'migrations/023_ai_usage.sql'
   connection.executescript(migration.read_text())
  self.meter = g.UsageMeter(self.db, 'deepseek:deepseek-flash', 'manual')

 def limit(self, daily, monthly):
  with sqlite3.connect(self.db) as connection:
   connection.execute("INSERT OR REPLACE INTO workspace_settings VALUES ('ai_budget',?)",
                      (json.dumps({'daily_tokens': daily, 'monthly_tokens': monthly}),))

 def test_reservation_checks_both_budgets_and_settles_with_reported_tokens(self):
  self.limit(150, 100)
  request = self.meter.reserve('extraction', 90)
  self.meter.settle(request, {'prompt_tokens': 30, 'completion_tokens': 20})
  with self.assertRaisesRegex(g.ProviderError, 'месячного'):
   self.meter.reserve('synthesis', 51)
  request = self.meter.reserve('synthesis', 50)
  self.meter.settle(request, rejected=True)
  self.limit(60, 0)
  with self.assertRaisesRegex(g.ProviderError, 'дневного'):
   self.meter.reserve('extraction', 11)
  with sqlite3.connect(self.db) as connection:
   self.assertEqual(connection.execute('SELECT charged_tokens,state FROM ai_usage ORDER BY id').fetchall(),
                    [(50, 'reported'), (0, 'rejected')])

 def test_budget_stops_http_but_reuses_cached_fragments(self):
  payload = {'segments': [{'id': 10, 'text':'Назначили владельца закупки ткани'}]}
  data = {'model': 'deepseek:deepseek-flash', 'key': 'fake', 'stage': 'manual',
          'input': payload, '_meter': self.meter}
  result = {'summary': 'Назначили владельца', 'tasks': [], 'decisions': [], 'open_questions': []}
  with patch.object(g, 'request', return_value=result) as http:
   self.assertEqual(g.analyze(data), result)
   http.assert_called_once()
  self.limit(1, 1)
  with patch.object(g.urllib.request, 'build_opener') as http:
   self.assertEqual(g.analyze(data), result)
   with self.assertRaisesRegex(g.ProviderError, 'дневного'):
    g.analyze({**data, 'force': True})
   http.assert_not_called()

 def test_ollama_analysis_reuses_results_without_charging_external_budget(self):
  self.limit(1, 1)
  model = 'ollama:qwen3:4b-instruct-2507-q4_K_M'
  meter = g.UsageMeter(self.db, model, 'manual')
  data = {'model':model, 'input':{'segments':[{'id':1,'text':'Согласовали сроки'}]}, '_meter':meter}
  value = {'done':True, 'done_reason':'stop', 'message':{'content':
    '{"summary":"Согласовали сроки","open_questions":[],"tasks":[],"decisions":[]}' }}
  class Opener:
   def open(self, req, timeout): return Response(value)
  with patch.object(g.urllib.request, 'build_opener', return_value=Opener()) as open_http:
   self.assertEqual(g.analyze(data)['summary'], 'Согласовали сроки')
   self.assertEqual(g.analyze(data)['summary'], 'Согласовали сроки')
   open_http.assert_called_once()
  with sqlite3.connect(self.db) as connection:
   self.assertEqual(connection.execute('SELECT count(*) FROM ai_usage').fetchone(), (0,))

 def test_context_uses_only_matching_task_and_latest_linked_decision(self):
  snapshot = {
   'project_tasks': [{'id': 11, 'title': 'Заказать ткань для штор', 'revision': 4},
                     {'id': 22, 'title': 'Закрыть бюджет на машину'}],
   'project_decisions': [{'task_id': 11, 'text': 'Проверить образцы'}, {'task_id': 11, 'text': 'Старое'},
                         {'task_id': 22, 'text': 'Иная задача'}],
  }
  tasks, decisions, _ = g.relevant_context(snapshot, [{'text':'Перенести закупку ткани для штор'}], [])
  self.assertEqual(tasks, [{'id': 11, 'title': 'Заказать ткань для штор'}])
  self.assertEqual(decisions, [{'task_id': 11, 'text': 'Проверить образцы'}])

 def test_history_and_materials_are_selected_per_fragment(self):
  snapshot = {
   'project_tasks': [{'id': 11, 'title': 'Согласовать смету ткани',
                      'recent_change': {'due_date': {'before': '2026-11-30', 'after': '2026-11-24'}}}],
   'project_materials': [{'id': 1, 'label': 'Смета ткани', 'url': 'https://example.test/fabric',
                          'local_url': 'https://example.test/fabric?signature=synthetic'},
                         {'id': 2, 'label': 'Склад мебели', 'url': 'https://example.test/furniture'}]
  }
  initial = [{'id': 42, 'text': 'Обсудить смету ткани'}]
  history = [{'id': 42, 'text': 'Вернём прежний срок сметы ткани'}]
  self.assertNotIn('recent_change', g.relevant_context(snapshot, initial, [])[0][0])
  self.assertIn('recent_change', g.relevant_context(snapshot, history, [])[0][0])
  materials = g.relevant_materials(snapshot, history)
  self.assertEqual([link['id'] for link in materials], [1])
  self.assertNotIn('local_url', materials[0])
  result = {'tasks': [{'source_segment_ids': [42], 'material_ids': [1, 2]}], 'decisions': []}
  verified = g.verified_proposals(result, {'segments': history, 'project_materials': materials})
  self.assertEqual(verified['tasks'][0]['material_ids'], [1])

if __name__=='__main__':unittest.main()
