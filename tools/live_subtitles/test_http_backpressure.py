import concurrent.futures
from http.server import BaseHTTPRequestHandler
import socket
import threading
import unittest
import urllib.request
from service import BoundedHTTPServer

class BackpressureTests(unittest.TestCase):
    def test_slow_requests_are_bounded_and_capacity_recovers(self):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_GET(self):
                self.send_response(200);self.send_header('Content-Length','2');self.end_headers();self.wfile.write(b'OK')
        server=BoundedHTTPServer(('127.0.0.1',0),Handler,max_requests=2)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();address=server.server_address
        held=[]
        try:
            for _ in range(2):
                sock=socket.create_connection(address,timeout=2);sock.sendall(b'GET / HTTP/1.0\r\n');held.append(sock)
            # Wait until both requests are owned by handlers, without timing guesses.
            deadline=__import__('time').monotonic()+2
            while server.request_slots._value!=0:
                self.assertLess(__import__('time').monotonic(),deadline);__import__('time').sleep(.01)
            sock=socket.create_connection(address,timeout=2)
            with sock:self.assertIn(b'503 Service Unavailable',sock.recv(1024))
            for sock in held:sock.sendall(b'\r\n');self.assertIn(b'200 OK',sock.recv(1024));sock.close()
            held.clear()
            deadline=__import__('time').monotonic()+2
            while server.request_slots._value!=2:
                self.assertLess(__import__('time').monotonic(),deadline);__import__('time').sleep(.01)
            with urllib.request.urlopen('http://%s:%s/'%address,timeout=2) as f:self.assertEqual(f.read(),b'OK')
        finally:
            for sock in held:sock.close()
            server.shutdown();server.server_close();thread.join(timeout=2)
