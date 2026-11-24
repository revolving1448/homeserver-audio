import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock
import xml.etree.ElementTree as ET
from service import Bridge, Problem, public_feed, safe_audio_files, info_hash, TorrentRedirect, MagnetRedirect
import hashlib
import urllib.request


class BridgeTests(unittest.TestCase):
    def test_specialist_results_do_not_wait_for_general_indexers(self):
        self.bridge.config['preferred_audiobook_indexer_ids'] = [5]
        self.bridge.config['fallback_audiobook_indexer_ids'] = [1]
        self.bridge.prowlarr = Mock(return_value=[{'title': 'A book', 'protocol': 'torrent', 'size': 2000}])
        self.assertEqual(self.bridge.releases('A book')[0]['title'], 'A book')
        self.bridge.prowlarr.assert_called_once()
        self.assertIn('indexerIds=5', self.bridge.prowlarr.call_args.args[0])
        self.assertEqual(self.bridge.prowlarr.call_args.kwargs['timeout'], 18)

    def test_general_source_is_only_fallback_for_missing_or_failed_specialist(self):
        self.bridge.config['preferred_audiobook_indexer_ids'] = [5]
        self.bridge.config['fallback_audiobook_indexer_ids'] = [1]
        for first in [[], TimeoutError()]:
            self.bridge.prowlarr = Mock(side_effect=[first, [{'title': 'Fallback', 'protocol': 'torrent', 'size': 2000}]])
            self.assertEqual(self.bridge.releases('A book')[0]['title'], 'Fallback')
            self.assertEqual(self.bridge.prowlarr.call_count, 2)
            self.assertIn('indexerIds=1', self.bridge.prowlarr.call_args.args[0])

    def test_failed_sources_are_not_reported_as_confirmed_absence(self):
        self.bridge.config['preferred_audiobook_indexer_ids'] = [5]
        self.bridge.prowlarr = Mock(side_effect=TimeoutError())
        with self.assertRaises(Problem):
            self.bridge.releases('A book')

    def test_hash_identity_is_stable_for_torrent_and_magnet(self):
        info = b'd4:name4:book6:lengthi123ee'
        expected = hashlib.sha1(info).hexdigest()
        self.assertEqual(info_hash(b'd4:info' + info + b'e'), expected)
        self.assertEqual(info_hash('magnet:?xt=urn:btih:' + expected.upper()), expected)
        with self.assertRaises(Problem):
            info_hash('magnet:?xt=unknown')

    def test_redirect_never_forwards_arr_key_to_external_site(self):
        req = urllib.request.Request('http://localhost:9696/1/download', headers={'X-Api-Key': 'fixture-secret'})
        redirected = TorrentRedirect().redirect_request(req, None, 302, '', {}, 'https://publisher.example/book.torrent')
        self.assertNotIn('fixture-secret', str(redirected.headers))
        with self.assertRaises(MagnetRedirect):
            TorrentRedirect().http_error_302(req, None, 302, '', {'Location': 'magnet:?xt=urn:btih:' + 'a'*40})

    def test_other_download_categories_are_left_unchanged(self):
        self.bridge.qb = Mock(return_value=b'[{"category":"MediaFusion"}]')
        with self.assertRaises(Problem):
            self.bridge.existing_download('a'*40)
        self.bridge.qb.assert_called_once()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = {k: str(self.root / k) for k in ['state', 'staging', 'library', 'subsonic_credentials']}
        for key in ['staging', 'library']:
            Path(self.config[key]).mkdir()
        Path(self.config['subsonic_credentials']).write_text(json.dumps({'username': 'fixture', 'password': 'fixture'}))
        self.bridge = Bridge(self.config)

    def test_authentication_requires_existing_token(self):
        for auth in [None, {}, {'u': 'x', 'p': 'secret'}, {'u': '', 't': 'x', 's': 'y'}]:
            with self.assertRaises(Problem):
                self.bridge.authenticate(auth)

    def test_result_is_opaque_private_and_owner_bound(self):
        result = self.bridge.remember('one', {'title': 'A book', 'kind': 'release', '_release': {'downloadUrl': 'private-key-url'}})
        self.assertNotIn('_release', result)
        self.assertNotIn('private-key-url', json.dumps(result))
        with self.assertRaises(Problem):
            self.bridge.remembered('two', result['id'])
        self.assertEqual(self.bridge.remembered('one', result['id'])['title'], 'A book')

    def test_expired_results_cannot_be_downloaded(self):
        result = self.bridge.remember('one', {'title': 'A book'})
        with self.bridge.database() as db:
            db.execute('UPDATE results SET created=0')
        with self.assertRaises(Problem):
            self.bridge.remembered('one', result['id'])

    def test_feed_rejects_private_network_and_credentials(self):
        with self.assertRaises(Problem):
            public_feed('https://user:password@public.example/feed')
        with patch('service.socket.getaddrinfo', return_value=[(2, 1, 6, '', ('127.0.0.1', 443))]):
            with self.assertRaises(Problem):
                public_feed('https://public.example/feed')

    def test_download_requires_role(self):
        self.bridge.sonic = Mock(return_value={'user': {'adminRole': False, 'downloadRole': False}})
        with self.assertRaises(Problem):
            self.bridge.request_release('one', {'u': 'one'}, 'id')

    def test_duplicate_request_does_not_leak_server_paths(self):
        self.bridge.may_download = Mock()
        result = self.bridge.remember('one', {'kind': 'release'})
        self.bridge.save_job('one', {'id': 'job', 'result_id': result['id'], 'stage': '/private/stage', 'hash': 'hash', 'status': 'downloading'})
        response = self.bridge.request_release('one', {}, result['id'])
        self.assertNotIn('stage', response['job'])
        self.assertNotIn('hash', response['job'])

    def test_import_rejects_path_traversal_and_incomplete_files(self):
        base = Path(self.config['staging'])
        for row in [{'name': '../escape.mp3', 'size': 10, 'progress': 1}, {'name': 'missing.mp3', 'size': 10, 'progress': .9}]:
            with self.assertRaises(Problem):
                safe_audio_files(base, [row])

    def test_no_executable_or_non_audio_import(self):
        base = Path(self.config['staging'])
        (base / 'book.exe').write_bytes(b'fixture')
        with self.assertRaises(Problem):
            safe_audio_files(base, [{'name': 'book.exe', 'size': 7, 'progress': 1}])

    def test_complete_audio_import_is_atomic_and_keeps_original(self):
        base = Path(self.config['staging']) / 'job'
        base.mkdir()
        (base / 'chapter.mp3').write_bytes(b'fixture audio')
        self.bridge.qb = Mock(return_value=json.dumps([{'name': 'chapter.mp3', 'size': 13, 'progress': 1}]).encode())
        self.bridge.sonic = Mock(return_value={'status': 'ok'})
        job = {'id': 'abcdef012345', 'title': '../Book title', 'stage': str(base)}
        with patch('service.subprocess.run', return_value=Mock(returncode=0, stdout='{"streams":[{"codec_type":"audio"}]}')):
            self.bridge.import_finished(job, {'hash': 'fixture', 'save_path': str(base)})
        published = list(Path(self.config['library']).rglob('*.mp3'))
        self.assertEqual(len(published), 1)
        self.assertTrue(published[0].samefile(base / 'chapter.mp3'))
        self.assertEqual(job['status'], 'imported')
        self.bridge.sonic.assert_called_once()

    def test_corrupt_audio_is_not_published(self):
        base = Path(self.config['staging']) / 'job'
        base.mkdir()
        (base / 'bad.mp3').write_bytes(b'bad')
        self.bridge.qb = Mock(return_value=json.dumps([{'name': 'bad.mp3', 'size': 3, 'progress': 1}]).encode())
        with patch('service.subprocess.run', return_value=Mock(returncode=1, stdout='{}')):
            with self.assertRaises(Problem):
                self.bridge.import_finished({'id': 'job12345', 'title': 'Book', 'stage': str(base)}, {'hash': 'fixture', 'save_path': str(base)})
        self.assertFalse(list(Path(self.config['library']).iterdir()))

    def test_cross_mount_import_uses_verified_copy_before_publish(self):
        base = Path(self.config['staging']) / 'copy-job'
        base.mkdir()
        source = base / 'chapter.mp3'
        source.write_bytes(b'complete audio')
        self.bridge.qb = Mock(return_value=json.dumps([{'name': 'chapter.mp3', 'size': 14, 'progress': 1}]).encode())
        self.bridge.sonic = Mock(return_value={'status': 'ok'})
        with patch('service.os.link', side_effect=OSError(18, 'Cross-mount link')):
            with patch('service.subprocess.run', return_value=Mock(returncode=0, stdout='{"streams":[{"codec_type":"audio"}]}')):
                self.bridge.import_finished({'id': 'copy12345', 'title': 'Copy book', 'stage': str(base)}, {'hash': 'fixture', 'save_path': str(base)})
        published = list(Path(self.config['library']).rglob('*.mp3'))
        self.assertEqual(len(published), 1)
        self.assertEqual(published[0].read_bytes(), source.read_bytes())
        self.assertTrue(source.exists())

    def test_archive_rss_is_real_metadata_escaped_and_persistent(self):
        row = {'_archive': 'fixture_book', 'title': 'Book & title', 'author': 'A < B', 'image': None}
        payload = {'files': [{'name': '01_chapter.mp3', 'size': '99', 'source': 'original'}, {'name': '01_chapter.ogg', 'source': 'derivative'}]}
        with patch('service.fetch', return_value=json.dumps(payload).encode()):
            ident = self.bridge.archive_feed(row)
        restarted = Bridge(self.config)
        feed = ET.fromstring(restarted.feed(ident))
        self.assertEqual(feed.findtext('channel/title'), 'Book & title')
        self.assertEqual(len(feed.findall('channel/item')), 1)
        self.assertEqual(feed.find('channel/item/enclosure').get('type'), 'audio/mpeg')


if __name__ == '__main__':
    unittest.main()
