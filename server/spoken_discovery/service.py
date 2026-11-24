"""Private spoken-audio discovery and audiobook acquisition bridge (stdlib only).

Clients authenticate with their existing Subsonic token. Arr credentials never
leave the server. Download requests accept cached result IDs, never client URLs.
"""
import base64
import concurrent.futures
from contextlib import contextmanager
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.parse as parse
import urllib.request as request
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BOOK = 10 * 1024**3
AUDIO = {'.mp3', '.m4a', '.m4b', '.aac', '.ogg', '.opus', '.flac', '.wav'}
OPENER = request.build_opener(request.ProxyHandler({}))


class MagnetRedirect(Exception):
    pass


class TorrentRedirect(request.HTTPRedirectHandler):
    def http_error_302(self, req, fp, code, msg, headers):
        location = headers.get('Location', '')
        if location.startswith('magnet:?'):
            raise MagnetRedirect(location)
        return super().http_error_302(req, fp, code, msg, headers)

    http_error_301 = http_error_303 = http_error_307 = http_error_308 = http_error_302

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if newurl.startswith('magnet:?'):
            raise MagnetRedirect(newurl)
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None and parse.urlsplit(req.full_url).netloc != parse.urlsplit(newurl).netloc:
            redirected.remove_header('X-api-key')
            redirected.remove_header('Authorization')
        return redirected


class Problem(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def fetch(url, *, data=None, headers=None, limit=8 * 1024**2, timeout=35):
    req = request.Request(url, data=data, headers=headers or {})
    with OPENER.open(req, timeout=timeout) as response:
        body = response.read(limit + 1)
        if len(body) > limit:
            raise Problem('Upstream response is too large; narrow the search.', 502)
        return body


def public_feed(value):
    uri = parse.urlsplit(value)
    if uri.scheme not in ('http', 'https') or not uri.hostname or uri.username or uri.password:
        raise Problem('The catalogue returned an invalid feed address.')
    if uri.port not in (None, 80, 443):
        raise Problem('This feed uses an unsupported port.')
    addresses = socket.getaddrinfo(uri.hostname, uri.port or 443, type=socket.SOCK_STREAM)
    if not addresses or any(not ipaddress.ip_address(row[4][0]).is_global for row in addresses):
        raise Problem('Feed addresses must resolve to public internet servers.')
    return value


def safe_audio_files(base, entries):
    """Only complete, regular audio files contained in this job's staging tree."""
    base = Path(base).resolve(strict=True)
    if len(entries) > 500 or sum(int(x.get('size', 0)) for x in entries) > MAX_BOOK:
        raise Problem('Audiobook exceeds the import size/file limit.')
    result = []
    for row in entries:
        raw = Path(row['name'])
        if raw.is_absolute() or '..' in raw.parts:
            raise Problem('Unsafe download file path.')
        path = base / raw
        if path.is_symlink() or not path.resolve().is_relative_to(base):
            raise Problem('Download file escapes its staging folder.')
        if path.suffix.lower() in AUDIO:
            if float(row.get('progress', 0)) < 1 or not path.is_file():
                raise Problem('Audio file is not complete yet.')
            result.append(path)
    if not result:
        raise Problem('This download contains no supported audio files.')
    return result


def info_hash(source):
    if isinstance(source, str):
        for value in parse.parse_qs(parse.urlsplit(source).query).get('xt', []):
            if value.lower().startswith('urn:btih:'):
                value = value[9:]
                if re.fullmatch('[a-fA-F0-9]{40}', value):
                    return value.lower()
                if re.fullmatch('[A-Za-z2-7]{32}', value):
                    return base64.b32decode(value.upper()).hex()
        raise Problem('This torrent uses an unsupported magnet identifier.')
    data = source
    def skip(at, depth=0):
        if depth > 40 or at >= len(data):
            raise Problem('Invalid torrent metadata.')
        if data[at:at+1] == b'i':
            end = data.find(b'e', at+1)
            if end < 0:
                raise Problem('Invalid torrent metadata.')
            int(data[at+1:end])
            return end + 1
        if data[at:at+1] in (b'd', b'l'):
            at += 1
            while at < len(data) and data[at:at+1] != b'e':
                at = skip(at, depth+1)
            if at >= len(data):
                raise Problem('Invalid torrent metadata.')
            return at + 1
        colon = data.find(b':', at)
        if colon < 0:
            raise Problem('Invalid torrent metadata.')
        length = int(data[at:colon])
        if length < 0 or colon + 1 + length > len(data):
            raise Problem('Invalid torrent metadata.')
        return colon + 1 + length
    if not data.startswith(b'd'):
        raise Problem('Invalid torrent metadata.')
    at = 1
    while at < len(data) and data[at:at+1] != b'e':
        end = skip(at)
        key = data[data.index(b':', at)+1:end]
        at = end
        end = skip(at)
        if key == b'info':
            return hashlib.sha1(data[at:end]).hexdigest()
        at = end
    raise Problem('Torrent metadata has no info dictionary.')


class Bridge:
    def __init__(self, config):
        self.config = config
        self.state = Path(config['state'])
        self.state.mkdir(parents=True, exist_ok=True)
        secret_path = self.state / 'feed-secret'
        try:
            with os.fdopen(os.open(secret_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
                stream.write(secrets.token_bytes(32))
        except FileExistsError:
            pass
        self.feed_secret = secret_path.read_bytes()
        if len(self.feed_secret) != 32:
            raise RuntimeError('The persistent feed secret is invalid; restore it from backup.')
        self.db = self.state / 'discovery.sqlite'
        self.mutations = threading.Lock()
        self.librivox_retry_after = 0
        with self.database() as db:
            db.execute('CREATE TABLE IF NOT EXISTS results(id TEXT PRIMARY KEY, owner TEXT, created REAL, payload TEXT)')
            db.execute('CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, owner TEXT, payload TEXT)')
            db.execute('CREATE TABLE IF NOT EXISTS feeds(id TEXT PRIMARY KEY, payload TEXT)')

    @contextmanager
    def database(self):
        connection = sqlite3.connect(self.db, timeout=15)
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def sonic(self, auth, method, params=None):
        fields = {**auth, **(params or {}), 'v': '1.15.0', 'c': 'HomeServerAudio', 'f': 'json'}
        value = json.loads(fetch(self.config['airsonic'].rstrip('/') + '/rest/' + method + '.view',
                                 data=parse.urlencode(fields).encode(),
                                 headers={'Content-Type': 'application/x-www-form-urlencoded'}))
        envelope = value.get('subsonic-response', {})
        if envelope.get('status') != 'ok':
            code = envelope.get('error', {}).get('code')
            raise Problem('Spoken-audio sign-in or permission was rejected.' if code in (40, 41, 50)
                          else 'The spoken-audio server could not complete this request.', 403)
        return envelope

    def authenticate(self, value):
        if not isinstance(value, dict) or set(value) != {'u', 't', 's'}:
            raise Problem('Use your existing spoken-audio token to sign in.', 401)
        if not all(isinstance(v, str) and 1 <= len(v) <= 160 for v in value.values()):
            raise Problem('Invalid sign-in.', 401)
        self.sonic(value, 'ping')
        return value['u'], value

    def may_download(self, auth):
        user = self.sonic(auth, 'getUser', {'username': auth['u']}).get('user', {})
        if not (user.get('adminRole') or user.get('downloadRole')):
            raise Problem('This account does not have download permission.', 403)

    def remember(self, owner, row):
        ident = secrets.token_urlsafe(20)
        with self.database() as db:
            db.execute('DELETE FROM results WHERE created < ?', (time.time() - 86400,))
            db.execute('INSERT INTO results VALUES(?,?,?,?)', (ident, owner, time.time(), json.dumps(row)))
        return {k: v for k, v in row.items() if not k.startswith('_')} | {'id': ident}

    def remembered(self, owner, ident):
        with self.database() as db:
            row = db.execute('SELECT payload FROM results WHERE id=? AND owner=? AND created>?',
                             (ident, owner, time.time() - 86400)).fetchone()
        if not row:
            raise Problem('This result expired. Search again.', 404)
        return json.loads(row[0])

    def catalogue(self, category, query):
        headers = {'User-Agent': 'HomeServerAudio/1.0', 'Accept': 'application/json'}
        if category == 'podcasts':
            url = 'https://itunes.apple.com/search?' + parse.urlencode({
                'term': query or 'podcast', 'media': 'podcast', 'entity': 'podcast', 'limit': 30, 'country': 'AU'})
            data = json.loads(fetch(url, headers=headers, limit=4 * 1024**2))
            return [{'kind': 'podcast', 'title': x.get('collectionName', 'Podcast'),
                     'author': x.get('artistName', ''), 'image': x.get('artworkUrl600') or x.get('artworkUrl100'),
                     'source': 'Podcast catalogue', '_feed': x['feedUrl']}
                    for x in data.get('results', []) if x.get('feedUrl')]
        params = {'format': 'json', 'limit': 40, 'extended': 1, 'coverart': 1, 'sort_order': 'desc'}
        if query:
            params['title'] = query
        try:
            if time.time() < self.librivox_retry_after:
                raise OSError('Catalogue cooldown')
            data = json.loads(fetch('https://librivox.org/api/feed/audiobooks?' + parse.urlencode(params), headers=headers, timeout=15))
        except Exception:
            self.librivox_retry_after = time.time() + 300
            return self.archive_catalogue(query)
        rows = [{'kind': 'book', 'title': x.get('title', 'Audiobook'),
                 'author': ', '.join(' '.join([a.get('first_name', ''), a.get('last_name', '')]).strip()
                                     for a in x.get('authors', [])),
                 'image': x.get('coverart_jpg'), 'source': 'LibriVox', '_feed': x['url_rss']}
                for x in data.get('books', []) if x.get('url_rss') and x.get('language') == 'English']
        return rows or self.archive_catalogue(query)

    def archive_catalogue(self, query):
        term = query.replace('"', ' ').replace('\\', ' ').strip()
        expression = 'collection:librivoxaudio AND mediatype:audio AND (language:eng OR language:English)'
        if term:
            expression += f' AND (title:("{term}") OR creator:("{term}"))'
        url = 'https://archive.org/advancedsearch.php?' + parse.urlencode({
            'q': expression, 'output': 'json', 'rows': 30, 'fl[]': ['identifier', 'title', 'creator'], 'sort[]': 'addeddate desc'}, doseq=True)
        data = json.loads(fetch(url, headers={'User-Agent': 'HomeServerAudio/1.0'}, timeout=25))
        def text(value):
            return ', '.join(str(x) for x in value) if isinstance(value, list) else str(value or '')
        return [{'kind': 'book', 'title': text(x.get('title')), 'author': text(x.get('creator')),
                 'image': 'https://archive.org/services/img/' + parse.quote(x['identifier'], safe=''),
                 'source': 'Internet Archive · LibriVox', '_archive': x['identifier']}
                for x in data.get('response', {}).get('docs', []) if x.get('identifier')]

    def prowlarr(self, path):
        key = ET.parse(self.config['prowlarr_config']).getroot().findtext('ApiKey')
        return json.loads(fetch(self.config['prowlarr'].rstrip('/') + path, headers={'X-Api-Key': key}, timeout=55))

    def releases(self, query):
        if not query:
            return []
        rows = self.prowlarr('/api/v1/search?' + parse.urlencode({'query': query, 'categories': 3030, 'type': 'search'}))
        return [{'kind': 'release', 'title': x.get('title', 'Audiobook'), 'author': '', 'image': None,
                 'source': x.get('indexer', 'Indexer'), 'bytes': x.get('size', 0),
                 'seeders': x.get('seeders', 0), '_release': x}
                for x in rows if str(x.get('protocol', '')).lower() == 'torrent'
                and 0 < int(x.get('size', 0)) <= MAX_BOOK][:50]

    def search(self, owner, category, query):
        if category not in ('podcasts', 'audiobooks') or not isinstance(query, str) or len(query) > 160:
            raise Problem('Choose a category and a search of at most 160 characters.')
        results, warnings = [], []
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            pending = {'catalogue': executor.submit(self.catalogue, category, query.strip())}
            if category == 'audiobooks' and query.strip():
                pending['indexers'] = executor.submit(self.releases, query.strip())
            for source, future in pending.items():
                try:
                    results.extend(future.result())
                except Exception:
                    warnings.append(f'{source.capitalize()} is unavailable at the moment; other results are still usable.')
        return {'results': [self.remember(owner, row) for row in results], 'warnings': warnings}

    def qb(self, path, params=None):
        data = None if params is None else parse.urlencode(params).encode()
        return fetch(self.config['qbittorrent'].rstrip('/') + '/api/v2/' + path, data=data,
                     headers={'Referer': self.config['qbittorrent'] + '/', 'Content-Type': 'application/x-www-form-urlencoded'})

    def save_job(self, owner, job):
        with self.database() as db:
            db.execute('INSERT OR REPLACE INTO jobs VALUES(?,?,?)', (job['id'], owner, json.dumps(job)))

    def jobs(self, owner=None):
        with self.database() as db:
            rows = db.execute('SELECT owner,payload FROM jobs' + (' WHERE owner=?' if owner else ''),
                              (owner,) if owner else ()).fetchall()
        return [(who, json.loads(payload)) for who, payload in rows]

    def existing_download(self, torrent_hash):
        existing = json.loads(self.qb('torrents/info?' + parse.urlencode({'hashes': torrent_hash})))
        if not existing:
            return None
        if any(t.get('category') != 'homeserver-audiobooks' for t in existing):
            raise Problem('This torrent already belongs to another download task; it was left unchanged.', 409)
        for _, job in self.jobs():
            if job.get('hash') == torrent_hash:
                return {'job': self.visible_job(job)}
        raise Problem('This audiobook is already in the download client. Its existing download was left unchanged.', 409)

    def request_release(self, owner, auth, ident):
        self.may_download(auth)
        row = self.remembered(owner, ident)
        if row['kind'] != 'release':
            raise Problem('Select an audiobook download result.')
        for who, job in self.jobs():
            if job.get('result_id') == ident:
                return {'job': self.visible_job(job)}
        if sum(j['status'] in ('downloading', 'importing') for _, j in self.jobs()) >= 3:
            raise Problem('Three audiobook requests are already active. Wait for a download to finish.', 409)
        release = row['_release']
        source = release.get('magnetUrl') or release.get('downloadUrl')
        if not source:
            raise Problem('This indexer did not provide a download source.')
        job_id = secrets.token_hex(12)
        category = 'homeserver-audiobooks'
        stage = str(Path(self.config['staging']) / job_id)
        Path(stage).mkdir(parents=True, exist_ok=True)
        # Only our dedicated category is created; existing movie/music settings stay intact.
        categories = json.loads(self.qb('torrents/categories'))
        if category not in categories:
            self.qb('torrents/createCategory', {'category': category, 'savePath': self.config['staging']})
        params = {'category': category, 'savepath': stage, 'autoTMM': 'false',
                  'tags': 'hsa-' + job_id, 'dlLimit': 1048576}
        if source.startswith('magnet:?'):
            torrent_hash = info_hash(source)
            duplicate = self.existing_download(torrent_hash)
            if duplicate:
                return duplicate
            params['urls'] = source
            response = self.qb('torrents/add', params)
        else:
            # The only accepted HTTP source is a cached Prowlarr download route.
            base = parse.urlsplit(self.config['prowlarr'])
            url = parse.urlsplit(source)
            allowed_path = re.fullmatch(r'/\d+/download/?', url.path) or re.fullmatch(r'/api/v1/indexer/\d+/download/?', url.path)
            if (url.scheme, url.hostname, url.port) != (base.scheme, base.hostname, base.port) or not allowed_path:
                raise Problem('The indexer returned an unsupported download address.')
            key = ET.parse(self.config['prowlarr_config']).getroot().findtext('ApiKey')
            torrent_opener = request.build_opener(request.ProxyHandler({}), TorrentRedirect())
            try:
                with torrent_opener.open(request.Request(source, headers={'X-Api-Key': key}), timeout=35) as stream:
                    torrent = stream.read(8 * 1024**2 + 1)
                if len(torrent) > 8 * 1024**2:
                    raise Problem('Torrent metadata is too large.')
            except MagnetRedirect as redirect:
                torrent_hash = info_hash(str(redirect))
                duplicate = self.existing_download(torrent_hash)
                if duplicate:
                    return duplicate
                params['urls'] = str(redirect)
                response = self.qb('torrents/add', params)
                torrent = None
            if torrent is not None and not torrent.startswith(b'd'):
                raise Problem('The indexer did not return a torrent file.')
            if torrent is not None:
                torrent_hash = info_hash(torrent)
                duplicate = self.existing_download(torrent_hash)
                if duplicate:
                    return duplicate
            boundary = secrets.token_hex(20)
            chunks = []
            for key_name, value in params.items():
                chunks.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{key_name}"\r\n\r\n{value}\r\n'.encode())
            chunks.append(f'--{boundary}\r\nContent-Disposition: form-data; name="torrents"; filename="book.torrent"\r\nContent-Type: application/x-bittorrent\r\n\r\n'.encode() + (torrent or b'') + b'\r\n')
            chunks.append(f'--{boundary}--\r\n'.encode())
            if torrent is not None:
                response = fetch(self.config['qbittorrent'] + '/api/v2/torrents/add', data=b''.join(chunks),
                                 headers={'Content-Type': 'multipart/form-data; boundary=' + boundary,
                                          'Referer': self.config['qbittorrent'] + '/'})
        if response.strip() != b'Ok.':
            raise Problem('The download client rejected this request.', 502)
        job = {'id': job_id, 'result_id': ident, 'title': row['title'], 'status': 'downloading',
               'progress': 0, 'stage': stage, 'hash': torrent_hash, 'created': time.time()}
        self.save_job(owner, job)
        return {'job': self.visible_job(job)}

    @staticmethod
    def visible_job(job):
        return {k: v for k, v in job.items() if k not in ('stage', 'result_id', 'hash')}

    def subscribe(self, owner, auth, ident):
        row = self.remembered(owner, ident)
        if row['kind'] not in ('podcast', 'book'):
            raise Problem('Select a podcast or catalogue audiobook.')
        if row.get('_archive'):
            feed_id = self.archive_feed(row)
            feed = self.config['feed_base'].rstrip('/') + '/feeds/books/' + feed_id + '.xml'
        else:
            feed = public_feed(row['_feed'])
        existing = self.sonic(auth, 'getPodcasts', {'includeEpisodes': 'false'}).get('podcasts', {}).get('channel', [])
        if not any(x.get('url', '').rstrip('/') == feed.rstrip('/') for x in existing):
            self.sonic(auth, 'createPodcastChannel', {'url': feed})
        return {'subscribed': True, 'message': 'Added. Open your library and choose an episode or chapter to download.'}

    def archive_feed(self, row):
        identifier = row['_archive']
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,180}', identifier):
            raise Problem('Invalid catalogue identifier.')
        metadata = json.loads(fetch('https://archive.org/metadata/' + identifier))
        files = [x for x in metadata.get('files', []) if x.get('source') == 'original'
                 and x.get('name', '').lower().endswith('.mp3')]
        if not files or len(files) > 500:
            raise Problem('This catalogue item has no supported original audio chapters.')
        chapters = [{'title': str(x.get('title') or x['name']), 'bytes': int(x.get('size', 0)),
                     'url': 'https://archive.org/download/' + identifier + '/' + parse.quote(x['name'], safe='/')}
                    for x in sorted(files, key=lambda x: x['name']) if 0 < int(x.get('size', 0)) <= MAX_BOOK]
        if not chapters:
            raise Problem('No playable chapters found.')
        ident = hmac.new(self.feed_secret, identifier.encode(), hashlib.sha256).hexdigest()[:32]
        with self.database() as db:
            db.execute('INSERT OR REPLACE INTO feeds VALUES(?,?)', (ident, json.dumps({
                'title': row['title'], 'author': row['author'], 'image': row.get('image'), 'chapters': chapters})))
        return ident

    def feed(self, ident):
        with self.database() as db:
            row = db.execute('SELECT payload FROM feeds WHERE id=?', (ident,)).fetchone()
        if row is None:
            raise Problem('Not found', 404)
        data = json.loads(row[0])
        root = ET.Element('rss', version='2.0', attrib={'xmlns:itunes': 'http://www.itunes.com/dtds/podcast-1.0.dtd'})
        channel = ET.SubElement(root, 'channel')
        ET.SubElement(channel, 'title').text = data['title']
        ET.SubElement(channel, 'description').text = 'LibriVox audiobook: ' + data['title']
        ET.SubElement(channel, 'link').text = 'https://archive.org/'
        ET.SubElement(channel, 'language').text = 'en'
        ET.SubElement(channel, 'itunes:author').text = data['author']
        if data.get('image'):
            ET.SubElement(channel, 'itunes:image', href=data['image'])
        for index, chapter in enumerate(data['chapters']):
            item = ET.SubElement(channel, 'item')
            ET.SubElement(item, 'title').text = f'{index + 1:03d} · ' + chapter['title']
            ET.SubElement(item, 'guid', isPermaLink='false').text = ident + ':' + str(index)
            ET.SubElement(item, 'itunes:episode').text = str(index + 1)
            ET.SubElement(item, 'enclosure', url=chapter['url'], length=str(chapter['bytes']), type='audio/mpeg')
        return ET.tostring(root, encoding='utf-8', xml_declaration=True)

    def import_finished(self, job, torrent):
        base = Path(torrent.get('save_path', job['stage'])).resolve()
        expected = Path(job['stage']).resolve()
        if base != expected:
            raise Problem('The download client changed this request’s staging folder.')
        files = json.loads(self.qb('torrents/files?' + parse.urlencode({'hash': torrent['hash']})))
        audio = safe_audio_files(base, files)
        library = Path(self.config['library'])
        title = re.sub(r'[^\w .()-]', '_', job['title'])[:120].strip('. ') or 'Audiobook'
        destination = library / (title + ' [' + job['id'][:8] + ']')
        publish = Path(self.config['staging']) / '.imports' / job['id']
        publish.mkdir(parents=True, exist_ok=True)
        if library.stat().st_dev != publish.stat().st_dev:
            raise Problem('Audiobook staging and library must be on the same filesystem for atomic import.')
        for index, path in enumerate(audio):
            probe = subprocess.run(['ffprobe', '-protocol_whitelist', 'file,pipe', '-v', 'error', '-show_entries', 'stream=codec_type', '-of', 'json', str(path)],
                                   capture_output=True, text=True, timeout=25)
            if probe.returncode or not any(x.get('codec_type') == 'audio' for x in json.loads(probe.stdout).get('streams', [])):
                raise Problem('A downloaded file could not be verified as audio.')
            target = publish / path.relative_to(base)
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                if not target.samefile(path):
                    raise Problem('An unexpected file already exists in this request’s import staging folder.')
                continue
            try:
                os.link(path, target)
            except OSError as error:
                if error.errno != 18:  # Different service mount namespace/bind.
                    raise
                shutil.copyfile(path, target)
                def digest(file):
                    with file.open('rb') as stream:
                        return hashlib.file_digest(stream, 'sha256').digest()
                if digest(path) != digest(target):
                    raise Problem('The staged audiobook copy failed verification.')
        # All audio is validated before publishing the entire book atomically.
        # Hard links retain the original download for seeding; no files move.
        if not destination.exists():
            os.rename(publish, destination)
        admin = json.loads(Path(self.config['subsonic_credentials']).read_text())
        salt = secrets.token_hex(8)
        auth = {'u': admin['username'], 's': salt,
                't': hashlib.md5((admin['password'] + salt).encode()).hexdigest()}
        self.sonic(auth, 'startScan')
        job.update(status='imported', progress=1, message='Files added; library scan requested. Refresh Audiobooks.')

    def retry(self, owner, auth, ident):
        self.may_download(auth)
        found = next((job for _, job in self.jobs(owner) if job['id'] == ident), None)
        if found is None or found['status'] != 'failed':
            raise Problem('Select a failed audiobook request.', 404)
        found.update(status='downloading', progress=0)
        found.pop('message', None)
        self.save_job(owner, found)
        return {'job': self.visible_job(found)}

    def tick(self):
        active = [(owner, job) for owner, job in self.jobs() if job['status'] in ('downloading', 'importing')]
        if not active:
            return
        torrents = json.loads(self.qb('torrents/info?' + parse.urlencode({'category': 'homeserver-audiobooks'})))
        for owner, job in active:
            torrent = next((x for x in torrents if 'hsa-' + job['id'] in [t.strip() for t in x.get('tags', '').split(',')]), None)
            if torrent is None:
                continue
            try:
                if int(torrent.get('total_size', 0)) > MAX_BOOK:
                    try:
                        self.qb('torrents/pause', {'hashes': torrent['hash']})
                    except Exception:
                        try:
                            self.qb('torrents/stop', {'hashes': torrent['hash']})
                        except Exception:
                            pass
                    raise Problem('The torrent metadata exceeds the audiobook size limit.')
                job['progress'] = float(torrent.get('progress', 0))
                if job['progress'] >= 1:
                    job['status'] = 'importing'
                    self.save_job(owner, job)
                    self.import_finished(job, torrent)
            except Exception as error:
                print(f"Audiobook import {job['id']} failed ({type(error).__name__})", flush=True)
                job.update(status='failed', message=str(error) if isinstance(error, Problem)
                           else 'Import failed; the downloaded files have been retained for inspection.')
            self.save_job(owner, job)


def main():
    config = json.loads(Path(os.environ['HOMESERVER_DISCOVERY_CONFIG']).read_text())
    bridge = Bridge(config)
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # Never log authentication, search terms or download URLs.

        def respond(self, status, value):
            body = json.dumps(value).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            match = re.fullmatch(r'/feeds/books/([a-f0-9]{32})\.xml', self.path)
            if match:
                try:
                    body = bridge.feed(match.group(1))
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/rss+xml; charset=utf-8')
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except Problem as error:
                    self.respond(error.status, {'error': str(error)})
                return
            self.respond(200 if self.path == '/health' else 404,
                         {'status': 'ok'} if self.path == '/health' else {'error': 'Not found'})

        def do_POST(self):
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 32768:
                    raise Problem('Invalid request size.')
                args = json.loads(self.rfile.read(length))
                owner, auth = bridge.authenticate(args.get('auth'))
                if self.path == '/v1/search':
                    value = bridge.search(owner, args.get('category'), args.get('query', ''))
                elif self.path == '/v1/subscribe':
                    with bridge.mutations:
                        value = bridge.subscribe(owner, auth, args.get('id'))
                elif self.path == '/v1/request':
                    with bridge.mutations:
                        value = bridge.request_release(owner, auth, args.get('id'))
                elif self.path == '/v1/jobs':
                    value = {'jobs': [bridge.visible_job(job) for _, job in bridge.jobs(owner)][-40:]}
                elif self.path == '/v1/retry':
                    with bridge.mutations:
                        value = bridge.retry(owner, auth, args.get('id'))
                else:
                    raise Problem('Not found', 404)
                self.respond(200, value)
            except Problem as error:
                self.respond(error.status, {'error': str(error)})
            except Exception:
                self.respond(502, {'error': 'A connected service did not respond. Retry shortly.'})

    def worker():
        while True:
            try:
                bridge.tick()
            except Exception:
                pass  # Next local poll retries; no AI/Dell investigation loop.
            time.sleep(30)
    threading.Thread(target=worker, daemon=True).start()
    servers = [ThreadingHTTPServer((host, config.get('port', 4041)), Handler) for host in config['bind']]
    for server in servers[:-1]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    servers[-1].serve_forever()


if __name__ == '__main__':
    main()
