import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        has_result = any(m.get('role') == 'tool' for m in body['messages'])
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        if has_result:
            chunks = [
                {'choices': [{'delta': {'content': 'Approved and ran.'}}]},
                {'choices': [{'delta': {}, 'finish_reason': 'stop'}]},
                {'choices': [], 'usage': {'prompt_tokens': 40, 'completion_tokens': 8}},
            ]
        else:
            chunks = [
                {'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'call_approval_safe', 'type': 'function', 'function': {'name': 'bash', 'arguments': json.dumps({'command': 'sudo echo auto-accept-test'})}}]}}]},
                {'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}]},
                {'choices': [], 'usage': {'prompt_tokens': 40, 'completion_tokens': 8}},
            ]
        for chunk in chunks:
            self.wfile.write(b'data: ' + json.dumps(chunk).encode() + b'\n\n')
        self.wfile.write(b'data: [DONE]\n\n')

    def log_message(self, *args):
        pass


HTTPServer(('127.0.0.1', 18163), H).serve_forever()
