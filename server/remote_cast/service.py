"""Playback-only capability gateway. Minting is private; public routes never accept credentials."""
import hashlib
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import threading
import time
import urllib.error
import urllib.parse as parse
import urllib.request as request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Problem(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status

class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

OPENER = request.build_opener(request.ProxyHandler({}), NoRedirect)

class Gateway:
    def __init__(self, config, now=time.time):
        self.config, self.now = config, now
        self.state = Path(config['state'])
        self.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.db = self.state / 'tokens.sqlite'
        self.lock = threading.RLock()
        self.auth_cache = {}
        with self.database() as db:
            db.execute('CREATE TABLE IF NOT EXISTS tokens (digest TEXT PRIMARY KEY, owner TEXT NOT NULL, target TEXT NOT NULL, kind TEXT NOT NULL, expires REAL NOT NULL)')
        self.db.chmod(0o600)

    @contextmanager
    def database(self):
        connection = sqlite3.connect(self.db, timeout=5)
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def source(self, value, kind):
        if not isinstance(value, str) or len(value) > 10000:
            raise Problem('Invalid media address.')
        uri = parse.urlsplit(value)
        if uri.scheme not in ('http', 'https') or uri.username or uri.password or uri.fragment:
            raise Problem('Unsupported media address.')
        try:
            allowed = uri.hostname in self.config['allowed_hosts'] and uri.port in self.config['allowed_ports']
        except ValueError:
            allowed = False
        methods = {'audio': '/rest/stream.view', 'art': '/rest/getCoverArt.view'}
        if not allowed or uri.path != methods[kind]:
            raise Problem('Only configured Subsonic playback and artwork are allowed.')
        params = parse.parse_qs(uri.query, keep_blank_values=True)
        if any(len(values) != 1 for values in params.values()):
            raise Problem('Ambiguous playback parameters.')
        if not all(params.get(k, [''])[0] for k in ['u', 't', 's', 'id']) or 'p' in params:
            raise Problem('Reconnect with token authentication before remote casting.')
        # Always connect to the local service, never arbitrary DNS or a supplied host.
        local = parse.urlunsplit(('http', '127.0.0.1:' + str(uri.port), uri.path, uri.query, ''))
        auth = {k: params[k][0] for k in ['u', 't', 's']}
        return local, uri.port, auth

    def verify(self, port, auth):
        key = hashlib.sha256(json.dumps([port, auth], sort_keys=True).encode()).hexdigest()
        with self.lock:
            if self.auth_cache.get(key, 0) > self.now():
                return
        fields = {**auth, 'v': '1.15.0', 'c': 'HomeServerCast', 'f': 'json'}
        req = request.Request(f'http://127.0.0.1:{port}/rest/ping.view', data=parse.urlencode(fields).encode(), headers={'Content-Type': 'application/x-www-form-urlencoded'})
        try:
            with OPENER.open(req, timeout=8) as response:
                data = json.loads(response.read(65537))
            if data.get('subsonic-response', {}).get('status') != 'ok':
                raise Problem('The media login was rejected.', 401)
        except Problem:
            raise
        except Exception:
            raise Problem('The media server could not verify your login.', 502)
        with self.lock:
            self.auth_cache = {k: expiry for k, expiry in self.auth_cache.items() if expiry > self.now()}
            self.auth_cache[key] = self.now() + 60

    def issue(self, owner, target, kind):
        token = secrets.token_urlsafe(32)
        expiry = self.now() + self.config.get('ttl_seconds', 21600)
        with self.lock, self.database() as db:
            db.execute('DELETE FROM tokens WHERE expires <= ?', (self.now(),))
            count = db.execute('SELECT COUNT(*) FROM tokens WHERE owner=?', (owner,)).fetchone()[0]
            if count >= 2000:
                raise Problem('Too many active cast links; retry later.', 429)
            db.execute('INSERT INTO tokens VALUES(?,?,?,?,?)', (hashlib.sha256(token.encode()).hexdigest(), owner, target, kind, expiry))
        route = 'play' if kind == 'audio' else 'cover'
        return self.config['public_base'].rstrip('/') + '/' + route + '?token=' + token

    def mint(self, args):
        target, port, auth = self.source(args.get('media_url'), 'audio')
        self.verify(port, auth)
        owner = hashlib.sha256(f'{port}:{auth["u"]}'.encode()).hexdigest()
        art = None
        if args.get('art_url'):
            art_target, art_port, art_auth = self.source(args['art_url'], 'art')
            if art_port != port or art_auth != auth:
                raise Problem('Artwork must use the same media account.')
            art = self.issue(owner, art_target, 'art')
        return {'media_url': self.issue(owner, target, 'audio'), 'art_url': art,
                'expires_in': self.config.get('ttl_seconds', 21600)}

    def lookup(self, token, kind):
        if not isinstance(token, str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}', token):
            raise Problem('Link not found.', 404)
        with self.database() as db:
            row = db.execute('SELECT target,expires,kind FROM tokens WHERE digest=?', (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
        if not row or row[1] <= self.now() or row[2] != kind:
            raise Problem('Link not found or expired.', 404)
        return row[0]

class BoundedServer(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(*args, **kwargs)
    def process_request(self, request_socket, address):
        if not self.slots.acquire(blocking=False):
            request_socket.sendall(b'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
            self.shutdown_request(request_socket)
            return
        try:
            super().process_request(request_socket, address)
        except Exception:
            self.slots.release()
            raise
    def process_request_thread(self, request_socket, address):
        try:
            request_socket.settimeout(20)
            super().process_request_thread(request_socket, address)
        finally:
            self.slots.release()
    def handle_error(self, request_socket, client_address):
        pass  # Never log raw URLs, tokens or credentials.

def handler(gateway, private=False):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *args):
            pass
        def headers_common(self):
            origin = self.headers.get('Origin', '')
            self.send_header('Access-Control-Allow-Origin', origin if re.fullmatch(r'https?://[A-Za-z0-9.:-]+', origin) else '*')
            self.send_header('Access-Control-Expose-Headers', 'Content-Length, Content-Range, Accept-Ranges')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Connection', 'close')
            self.close_connection = True
        def respond(self, status, body=None):
            data = json.dumps(body or {'error': 'Not found'}).encode()
            self.send_response(status);self.headers_common()
            self.send_header('Content-Type', 'application/json');self.send_header('Content-Length', str(len(data)));self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(data)
        def do_OPTIONS(self):
            self.send_response(204);self.headers_common();self.send_header('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');self.send_header('Access-Control-Allow-Headers', 'Range');self.send_header('Content-Length', '0');self.end_headers()
        def do_POST(self):
            if not private or self.path != '/v1/cast':
                self.respond(404);return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 20000:
                    raise Problem('Invalid request size.')
                args = json.loads(self.rfile.read(length))
                self.respond(200, gateway.mint(args))
            except Problem as error:
                self.respond(error.status, {'error': str(error)})
            except Exception:
                self.respond(502, {'error': 'Could not prepare remote casting.'})
        def do_HEAD(self):
            self.do_GET()
        def do_GET(self):
            headers_sent = False
            uri = parse.urlsplit(self.path)
            if private and uri.path == '/health':
                self.respond(200, {'status': 'ok'});return
            kind = {'/play': 'audio', '/cover': 'art'}.get(uri.path)
            if private or not kind:
                self.respond(404);return
            try:
                params = parse.parse_qs(uri.query)
                if set(params) != {'token'} or len(params['token']) != 1:
                    raise Problem('Link not found.', 404)
                target = gateway.lookup(params['token'][0], kind)
                headers = {}
                value = self.headers.get('Range')
                if value:
                    if not re.fullmatch(r'bytes=(?:[0-9]+-[0-9]*|-[0-9]+)', value):
                        raise Problem('Unsupported byte range.', 416)
                    headers['Range'] = value
                req = request.Request(target, headers=headers, method=self.command)
                try:
                    upstream = OPENER.open(req, timeout=20)
                except urllib.error.HTTPError as error:
                    raise Problem('Media is unavailable.', 416 if error.code == 416 else 502)
                with upstream:
                    ctype = upstream.headers.get('Content-Type', '').lower()
                    allowed = ctype.startswith('audio/') or ctype.startswith('application/octet-stream') if kind == 'audio' else ctype.startswith('image/')
                    if not allowed:
                        raise Problem('The server did not return playable media.', 502)
                    headers_sent = True
                    self.send_response(upstream.status);self.headers_common()
                    for name in ['Content-Type', 'Content-Length', 'Content-Range', 'Accept-Ranges']:
                        if upstream.headers.get(name):self.send_header(name, upstream.headers[name])
                    self.end_headers()
                    if self.command != 'HEAD':
                        while chunk := upstream.read(65536):self.wfile.write(chunk)
            except Problem as error:
                self.respond(error.status, {'error': str(error)})
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                pass
            except Exception:
                if not headers_sent:
                    self.respond(502, {'error': 'Playback source is temporarily unavailable.'})
                self.close_connection = True
    return Handler

def main():
    os.umask(0o077)
    config = json.loads(Path(os.environ.get('HOMESERVER_CAST_CONFIG', '/etc/homeserver-remote-cast/config.json')).read_text())
    gateway = Gateway(config)
    public = BoundedServer(('127.0.0.1', config.get('public_port', 4043)), handler(gateway))
    threading.Thread(target=public.serve_forever, daemon=True).start()
    servers = [BoundedServer((host, config.get('private_port', 4042)), handler(gateway, private=True)) for host in config['private_bind']]
    for server in servers[:-1]:threading.Thread(target=server.serve_forever, daemon=True).start()
    servers[-1].serve_forever()

if __name__ == '__main__':main()
