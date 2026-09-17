"""Local UI-test fixture; responses are canned and never call a model."""
import json
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        time.sleep(1.4)
        if body.get('model') == 'fixture-error':
            self.send_response(503)
            self.end_headers()
            return
        source = body['messages'][-1]['content']
        tokens = re.findall(r'_+TR_LITERAL_\d+__', source)
        translated = 'Please check this code and preserve API and variable names.'
        if tokens:
            translated += '\n' + '\n'.join(tokens)
        response = json.dumps({'choices': [{'message': {'content': translated}, 'finish_reason': 'stop'}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        try:
            self.wfile.write(response)
        except BrokenPipeError:
            pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
url = f'http://127.0.0.1:{server.server_port}/v1'
Path('/tmp/translator-ui-fixture-url').write_text(url)
print('Local test fixture:', url, flush=True)
server.serve_forever()
