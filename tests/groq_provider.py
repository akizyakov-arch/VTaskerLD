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

if __name__=='__main__':unittest.main()
