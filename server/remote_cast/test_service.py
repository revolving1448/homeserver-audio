import hashlib
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib import request, error, parse
from unittest.mock import Mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from service import Gateway, Problem, handler, BoundedServer

class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.now = 1000
        self.gateway = Gateway({'state':self.temp.name,'allowed_hosts':['100.64.0.1'],'allowed_ports':[5274], 'public_base':'https://cast.example', 'ttl_seconds':60}, now=lambda:self.now)
        self.url = 'http://100.64.0.1:5274/rest/stream.view?id=song&u=test&t=secret&s=salt'
        self.gateway.verify = Mock()
    def test_untrusted_addresses_and_admin_routes_never_proxy(self):
        for url in ['http://evil.example:5274/rest/stream.view?u=a&t=b&s=c&id=1',self.url.replace('/rest/stream.view','/api/admin/settings'),self.url.replace('http://','file://'),self.url.replace('100.64.0.1','user:password@100.64.0.1'),self.url+'&id=other']:
            with self.assertRaises(Problem):self.gateway.mint({'media_url':url})
        self.gateway.verify.assert_not_called()
    def test_links_expose_neither_credentials_nor_upstream_addresses(self):
        result=self.gateway.mint({'media_url':self.url});url=result['media_url'];token=parse.parse_qs(parse.urlsplit(url).query)['token'][0]
        self.assertNotIn('secret',json.dumps(result));self.assertNotIn('100.64',json.dumps(result))
        self.assertEqual(self.gateway.lookup(token,'audio'),'http://127.0.0.1:5274/rest/stream.view?id=song&u=test&t=secret&s=salt')
        self.now+=61
        with self.assertRaises(Problem):self.gateway.lookup(token,'audio')
    def test_unauthenticated_or_wrong_art_account_cannot_mint(self):
        with self.assertRaises(Problem):self.gateway.mint({'media_url':self.url.replace('&t=secret','')})
        art=self.url.replace('stream.view','getCoverArt.view').replace('u=test','u=other')
        with self.assertRaises(Problem):self.gateway.mint({'media_url':self.url,'art_url':art})
    def test_authentication_must_succeed(self):
        self.gateway.verify=Mock(side_effect=Problem('Denied',401))
        with self.assertRaises(Problem):self.gateway.mint({'media_url':self.url})
        with self.gateway.database() as db:self.assertEqual(db.execute('SELECT COUNT(*) FROM tokens').fetchone()[0],0)
    def test_bad_or_wrong_kind_tokens_are_rejected(self):
        result=self.gateway.mint({'media_url':self.url});token=parse.parse_qs(parse.urlsplit(result['media_url']).query)['token'][0]
        for candidate,kind in [('bad','audio'),(token,'art')]:
            with self.assertRaises(Problem):self.gateway.lookup(candidate,kind)
    def test_public_server_never_exposes_mint_or_health_routes(self):
        server=BoundedServer(('127.0.0.1',0),handler(self.gateway));threading.Thread(target=server.serve_forever,daemon=True).start()
        self.addCleanup(server.server_close);self.addCleanup(server.shutdown)
        base=f'http://127.0.0.1:{server.server_port}'
        for path,data in [('/v1/cast',b'{}'),('/health',None),('/rest/stream.view',None),('/play?token=bad',None)]:
            with self.assertRaises(error.HTTPError) as cm:request.urlopen(request.Request(base+path,data=data),timeout=3)
            self.assertEqual(cm.exception.code,404)
    def test_range_and_head_are_forwarded_without_redirects(self):
        payload=bytes(range(256))*100
        class Upstream(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_GET(self):
                span=self.headers.get('Range','');start,end=map(int,span[6:].split('-')) if span else (0,len(payload)-1)
                part=payload[start:end+1];self.send_response(206 if span else 200);self.send_header('Content-Type','audio/mpeg');self.send_header('Content-Length',str(len(part)));self.send_header('Content-Range',f'bytes {start}-{end}/{len(payload)}');self.end_headers()
                if self.command!='HEAD':self.wfile.write(part)
            def do_HEAD(self):self.do_GET()
        upstream=ThreadingHTTPServer(('127.0.0.1',0),Upstream);threading.Thread(target=upstream.serve_forever,daemon=True).start()
        self.addCleanup(upstream.server_close);self.addCleanup(upstream.shutdown)
        self.gateway.config['allowed_ports']=[upstream.server_port]
        result=self.gateway.mint({'media_url':self.url.replace(':5274',':'+str(upstream.server_port))})
        public=BoundedServer(('127.0.0.1',0),handler(self.gateway));threading.Thread(target=public.serve_forever,daemon=True).start()
        self.addCleanup(public.server_close);self.addCleanup(public.shutdown)
        suffix=parse.urlsplit(result['media_url']);url=f'http://127.0.0.1:{public.server_port}'+suffix.path+'?'+suffix.query
        with request.urlopen(request.Request(url,headers={'Range':'bytes=500-1499'}),timeout=3) as response:
            self.assertEqual(response.status,206);self.assertEqual(response.read(),payload[500:1500]);self.assertEqual(response.headers['Cache-Control'],'no-store')
        with request.urlopen(request.Request(url,method='HEAD'),timeout=3) as response:self.assertEqual(response.read(),b'');self.assertEqual(int(response.headers['Content-Length']),len(payload))

if __name__=='__main__':unittest.main()
