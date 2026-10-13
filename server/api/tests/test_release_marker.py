"""Health release source proof is additive and optional for existing packages."""
import asyncio
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from server.api import routes
from server.api.db import MuseumDatabase


class ReleaseMarkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.database = MuseumDatabase(self.root / 'museummuse.sqlite')
        self.marker = {'sourceCommit': 'a' * 40, 'batchId': 'batch-1', 'dataVersion': 'v1',
                       'sqliteSha256': 'b' * 64, 'manifestSha256': 'c' * 64}

    def test_missing_marker_keeps_old_health_fields(self):
        with patch.object(routes, 'database', self.database):
            payload = asyncio.run(routes.health()).model_dump(exclude_none=True)
        self.assertEqual(set(payload), {'ok', 'databaseReadable', 'dataVersion'})

    def test_packaged_marker_is_returned_in_health(self):
        (self.root / 'release-marker.json').write_text(json.dumps(self.marker))
        with patch.object(routes, 'database', self.database):
            payload = asyncio.run(routes.health()).model_dump(exclude_none=True)
        self.assertEqual(payload.get('releaseMarker'), self.marker)

    def test_invalid_marker_is_not_claimed_as_source_proof(self):
        (self.root / 'release-marker.json').write_text('{invalid')
        with patch.object(routes, 'database', self.database):
            payload = asyncio.run(routes.health()).model_dump(exclude_none=True)
        self.assertNotIn('releaseMarker', payload)

if __name__ == '__main__':
    unittest.main()
