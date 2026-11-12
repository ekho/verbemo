"""Real URLSession HTTP/WebSocket against a synthetic loopback CDP server.

Usage: python3 Tests/test_transport.py /absolute/path/to/call-integration-probe
No installed calling app, permission, microphone or credentials are used.
"""
import base64
import hashlib
import json
import socketserver
import struct
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/json/list':
            port = self.server.server_port
            body = json.dumps([{'id': 'window', 'type': 'page', 'url': 'https://synthetic.ktalk.ru/probe',
                                'webSocketDebuggerUrl': f'ws://127.0.0.1:{port}/devtools/page/window'}]).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path != '/devtools/page/window':
            self.send_error(404)
            return
        key = self.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
        self.end_headers()
        try:
            while True:
                header = self.rfile.read(2)
                if len(header) < 2 or header[0] & 15 == 8:
                    return
                n = header[1] & 127
                if n == 126: n = struct.unpack('!H', self.rfile.read(2))[0]
                if n == 127: n = struct.unpack('!Q', self.rfile.read(8))[0]
                if n > 1_048_576: return
                mask = self.rfile.read(4) if header[1] & 128 else b'\0' * 4
                data = self.rfile.read(n)
                request = json.loads(bytes(b ^ mask[i % 4] for i, b in enumerate(data)))
                self.server.requests.append(request['method'])
                index = len(self.server.requests)
                if index == 3:
                    response = {'id': request['id'], 'error': {'code': -1, 'message': 'synthetic disconnect'}}
                else:
                    value = {'kind': 'conference', 'joined': True,
                             'room': {'key': 'probe', 'title': 'Synthetic room', 'conference_id': 'c'},
                             'local_participant_id': 'self', 'microphone_muted': index != 2,
                             'camera_muted': True,
                             'participants': [{'id': 'self', 'name': 'Test Host', 'local': True, 'guest': False}]}
                    response = {'id': request['id'], 'result': {'result': {'type': 'object', 'value': value}}}
                payload = json.dumps(response).encode()
                frame = bytes([0x81, len(payload)]) if len(payload) < 126 else b'\x81\x7e' + struct.pack('!H', len(payload))
                self.wfile.write(frame + payload)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ValueError):
            return


class TransportTest(unittest.TestCase):
    def test_snapshot_mute_loss_and_reconnect(self):
        with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
            server.daemon_threads = True
            server.requests = []
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                run = subprocess.run([BINARY, 'https://synthetic.ktalk.ru', str(server.server_port), '4'],
                                     text=True, capture_output=True, timeout=20, check=True)
                rows = [json.loads(line) for line in run.stdout.splitlines()]
                self.assertEqual([r['participation'] for r in rows], ['inCall', 'inCall', 'unknown', 'inCall'])
                self.assertEqual([rows[i]['call']['microphoneMuted'] for i in [0, 1, 3]], [True, False, True])
                self.assertNotIn('call', rows[2])
                self.assertEqual(rows[0]['call']['participants'][0]['name'], 'Test Host')
                self.assertEqual(server.requests, ['Runtime.evaluate'] * 4)
            finally:
                server.shutdown()


if __name__ == '__main__':
    BINARY = sys.argv.pop(1)
    unittest.main()
