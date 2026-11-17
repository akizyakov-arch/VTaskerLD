# -*- coding: utf-8 -*-
"""Offline provider contract tests: no credentials, Keychain writes or network."""
import importlib.util,json,unittest,urllib.error
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
 def test_long_input_chunks_and_deduplicates(self):
  calls=[]
  def request(data,payload,schema=g.SCHEMA):
   calls.append(payload)
   if 'parts' in payload and isinstance(payload['parts'],list):return {'summary':'combined','open_questions':[]}
   return {'summary':'part','open_questions':[],'tasks':[{'title':'same'}],'decisions':[]}
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
if __name__=='__main__':unittest.main()
