import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CHECKER = Path(__file__).resolve().parents[1] / 'spec_graph.py'

class SpecGraphTests(unittest.TestCase):
    def test_imported_specs_validate_local_code_and_ignore_independent_repos(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'client'; provider = Path(temp) / 'engine'
            (root/'app').mkdir(parents=True); (provider/'app').mkdir(parents=True)
            spec = '---\nname: shared\n---\nBehavior\n'
            (provider/'app/shared.md').write_text(spec)
            (root/'spec_sources.json').write_text(json.dumps({'sources': ['../engine']}))
            (root/'impl').mkdir(); sidecar = root/'impl/SPEC.md'
            sidecar.write_text(f'---\nimplements: shared\nspec-digest: {hashlib.sha256(spec.encode()).hexdigest()}\n---\n')
            nested = root/'independent'; (nested/'.git').mkdir(parents=True)
            (nested/'SPEC.md').write_text('not a sidecar\n')
            run = lambda: subprocess.run([sys.executable, str(CHECKER)], cwd=root, capture_output=True, text=True)
            good = run(); self.assertEqual(good.returncode, 0, good.stderr)
            self.assertIn('checked 1 SPEC.md', good.stdout)
            (provider/'app/shared.md').write_text(spec+'changed\n')
            self.assertIn('stale', run().stderr)
            (root/'spec_sources.json').write_text(json.dumps({'sources': ['../missing']}))
            self.assertIn('Missing spec provider', run().stderr)
            (root/'spec_sources_overrides.json').write_text(json.dumps({'sources': ['../engine']}))
            sidecar.write_text('---\nimplements: shared\n---\n')
            self.assertEqual(run().returncode, 0)

if __name__ == '__main__':
    unittest.main()
