#!/usr/bin/env python3
"""Validate the exact immutable geometry shipped to SceneKit, without authoring dependencies."""
import hashlib
import json
import math
from pathlib import Path
import struct
import sys


def validate(directory):
    catalog = json.loads((directory / 'catalog.json').read_text())
    assert catalog['version'] == 1
    assert set(catalog['collections']) == {'singularity', 'sovereign', 'prism', 'orbit', 'nova'}
    total = 0
    for identifier, asset in catalog['collections'].items():
        folder = directory / identifier
        assert 1 <= len(asset['meshes']) <= 32 and 1 <= len(asset['materials']) <= 32
        for material in asset['materials']:
            for key in ('diffuse', 'normal', 'metallic', 'rough', 'ao', 'emission'):
                if key in material:
                    name = material[key]
                    assert Path(name).name == name and (folder / name).is_file(), (identifier, name)
        for mesh in asset['meshes']:
            assert Path(mesh['file']).name == mesh['file']
            data = (folder / mesh['file']).read_bytes()
            count, indices = mesh['vertices'], mesh['indices']
            assert 3 <= count <= 200000 and 3 <= indices <= 1000000 and indices % 3 == 0
            assert 0 <= mesh['material'] < len(asset['materials'])
            assert len(data) == count * 32 + indices * 4
            assert hashlib.sha256(data).hexdigest() == mesh['sha256'], (identifier, mesh['file'])
            for row in struct.iter_unpack('<8f', data[:count*32]):
                assert all(math.isfinite(v) for v in row)
                assert all(abs(v) < 2 for v in row[:3]), 'Geometry must be centered and normalized'
                assert 0.99 < sum(v*v for v in row[3:6]) < 1.01
            assert max(i[0] for i in struct.iter_unpack('<I', data[count*32:])) < count
            total += indices // 3
    return total


if __name__ == '__main__':
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'ios/VO1DMessenger/Resources/ArtifactModels'
    print(f'Validated five local models ({validate(path):,} triangles).')

