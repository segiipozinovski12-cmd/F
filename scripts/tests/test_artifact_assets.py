import importlib.util
from pathlib import Path
import tempfile
import unittest
import shutil

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('validate_artifact_assets', ROOT / 'scripts/validate_artifact_assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)
SOURCE = ROOT / 'ios/VO1DMessenger/Resources/ArtifactModels'


class ArtifactAssetTests(unittest.TestCase):
    def test_shipped_models_have_complete_textures_valid_indices_and_finite_normals(self):
        self.assertGreater(assets.validate(SOURCE), 200000)

    def test_corrupted_or_missing_bundle_resources_are_rejected(self):
        for failure in ('geometry', 'texture'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                folder = Path(temporary) / 'ArtifactModels'
                shutil.copytree(SOURCE, folder)
                if failure == 'geometry':
                    path = folder / 'prism/mesh-0.vmesh'
                    data = bytearray(path.read_bytes()); data[0] ^= 1; path.write_bytes(data)
                else:
                    (folder / 'prism/m0-diffuse.jpg').unlink()
                with self.assertRaises(AssertionError):
                    assets.validate(folder)

