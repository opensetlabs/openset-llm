import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


LP = Path(__file__).with_name('lp.py')
SERVER = r'''
import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
import json

parser = argparse.ArgumentParser()
parser.add_argument('--host')
parser.add_argument('--port', type=int)
args = parser.parse_args()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply({'status': 'ok'})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.reply({'choices': [{'message': {'content': 'answer' * 500},
                                'logprobs': {'content': []}}]})

HTTPServer((args.host, args.port), Handler).serve_forever()
'''
LIMITED = r'''
import resource
import runpy
import sys
resource.setrlimit(resource.RLIMIT_FSIZE, (1024, 1024))
sys.path.insert(0, str(__import__('pathlib').Path(sys.argv[1]).parent))
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
'''


@unittest.skipUnless(sys.platform.startswith('linux'), 'requires a file-size resource limit')
class LogprobPublicationTest(unittest.TestCase):
    def test_failed_write_can_be_retried(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            server = root / 'server.py'
            server.write_text(SERVER)
            arms = root / 'arms.json'
            arms.write_text(json.dumps({'fixture': {'cmd': shlex.join([sys.executable, str(server)])}}))
            prompts = root / 'prompts.jsonl'
            prompts.write_text(''.join(json.dumps({'id': str(i), 'messages': [
                {'role': 'user', 'content': str(i)},
            ]}) + '\n' for i in range(2)))
            output = root / 'output'
            args = [str(LP), '--arms', str(arms), '--only', 'fixture',
                    '--prompts', str(prompts), '--out', str(output)]
            failed = subprocess.run([sys.executable, '-B', '-c', LIMITED, *args],
                                    capture_output=True, text=True, timeout=15)
            self.assertNotEqual(failed.returncode, 0, failed.stdout)
            result = output / 'fixture.jsonl'
            self.assertFalse(result.exists(), 'partial output would be skipped forever on retry')
            self.assertEqual(sorted(path.name for path in output.iterdir()), ['fixture.lp.log'])
            retry = subprocess.run([sys.executable, '-B', *args],
                                   capture_output=True, text=True, timeout=15)
            self.assertEqual(retry.returncode, 0, retry.stderr)
            rows = [json.loads(line) for line in result.read_text().splitlines()]
            self.assertEqual([row['prompt_id'] for row in rows], ['0', '1'])
            self.assertTrue(all(row['text'] == 'answer' * 500 for row in rows))
            before = result.read_bytes()
            arms.write_text('{}')
            completed = subprocess.run([sys.executable, '-B', *args],
                                       capture_output=True, text=True, timeout=15)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(result.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
