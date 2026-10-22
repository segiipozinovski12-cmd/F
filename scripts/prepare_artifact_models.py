#!/usr/bin/env python3
"""Convert the five supplied archives (safely extracted first) into local iOS assets.

Offline authoring only: assimp_py==1.2.0, numpy==2.3.5, Pillow==12.3.0.
Usage: python scripts/prepare_artifact_models.py /path/to/extracted-models
No converter or model download is needed to build or run the iOS app.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import struct

import assimp_py as ai
import numpy as np
from PIL import Image

OUTPUT = Path(__file__).resolve().parents[1] / 'ios/VO1DMessenger/Resources/ArtifactModels'
SPECS = [
    ('singularity', 'Chrome Unicorn', 'chrome-unicorn-balloon-sculpture', 'source/model.glb'),
    ('sovereign', 'Cyber Skull', 'cyber-skull', 'source/model/model/model.dae'),
    ('prism', 'Crystal', 'crystal', 'source/Crystal.fbx'),
    ('orbit', 'Chromed Crown', 'cyber-sigilism-chromed-crown', 'source/sketch1/sketch1.fbx'),
    ('nova', 'Cute Ghost', 'cute-ghost', 'source/Ghost.fbx'),
]


def image(path):
    result = Image.open(path)
    # Substance's 16-bit scalar textures must be scaled, not clipped to white.
    if result.mode in ('I;16', 'I'):
        result = Image.fromarray((np.asarray(result, dtype=np.float32) / 257).clip(0, 255).astype('uint8'))
    return result


def convert(root):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    catalog = {'version': 1, 'collections': {}}
    for identifier, title, directory, source in SPECS:
        folder = root / directory
        scene = ai.import_file(str(folder / source), ai.Process_Triangulate | ai.Process_JoinIdenticalVertices |
                               ai.Process_GenSmoothNormals | ai.Process_PreTransformVertices | ai.Process_SortByPType)
        meshes = [m for m in scene.meshes if identifier != 'nova' or scene.materials[m.material_index]['NAME'] == 'M_Ghost']
        vertices = [np.asarray(m.vertices).reshape(-1, 3) for m in meshes]
        low = np.concatenate(vertices).min(axis=0); high = np.concatenate(vertices).max(axis=0)
        center = (low + high) / 2
        # A side view of the balloon reveals the legs, face and horn. Other models face +Z.
        yaw = -0.95 if identifier == 'singularity' else 0
        rotation = np.array([[np.cos(yaw), 0, np.sin(yaw)], [0, 1, 0], [-np.sin(yaw), 0, np.cos(yaw)]])
        rotated = np.concatenate([(v - center) @ rotation.T for v in vertices])
        scale = 2.85 / np.ptp(rotated, axis=0).max()
        materials = []
        output = OUTPUT / identifier; output.mkdir(exist_ok=True)

        def texture(im, label, size=512, scalar=False):
            im.thumbnail((size, size), Image.Resampling.LANCZOS)
            im = im.convert('L' if scalar else 'RGB')
            name = label + ('.png' if scalar or label.endswith('normal') else '.jpg')
            im.save(output / name, optimize=True, **({'quality': 90, 'subsampling': 0} if name.endswith('.jpg') else {}))
            return name

        # Extract the GLB's embedded textures, rather than relying on duplicate external files.
        embedded = []
        if identifier == 'singularity':
            data = (folder / source).read_bytes(); length, _ = struct.unpack_from('<II', data, 12)
            gltf = json.loads(data[20:20+length]); binary = data[28+length:]
            for entry in gltf['images']:
                view = gltf['bufferViews'][entry['bufferView']]; start = view.get('byteOffset', 0)
                embedded.append(Image.open(io.BytesIO(binary[start:start+view['byteLength']])).copy())

        used_indices = list(dict.fromkeys(m.material_index for m in meshes))
        for idx in used_indices:
            mat = scene.materials[idx]; name = mat.get('NAME', 'Chrome')
            spec = {'name': name, 'color': [0.82, 0.85, 0.92], 'metalness': 0.95, 'roughness': 0.22}
            label = f'm{idx}'
            if identifier == 'singularity':
                spec.update(diffuse=texture(embedded[0].copy(), label+'-color', 1024),
                            normal=texture(embedded[2].copy(), label+'-normal', 1024),
                            metallic=texture(embedded[1].getchannel('B'), label+'-metallic', scalar=True),
                            rough=texture(embedded[1].getchannel('G'), label+'-rough', scalar=True))
            elif identifier == 'sovereign':
                textures = folder / 'source/model/model/textures'
                channels = {'diffuse': ('albedo', False), 'normal': ('normal', False), 'metallic': ('metallic', True),
                            'rough': ('roughness', True), 'ao': ('AO', True), 'emission': ('emissive', False)}
                for key, (suffix, scalar) in channels.items():
                    candidates = sorted(textures.glob(f'{name}_{suffix}.*'))
                    if candidates:
                        spec[key] = texture(image(candidates[0]), label+'-'+key, 512 if key in ('diffuse', 'normal') else 256, scalar)
                if 'diffuse' not in spec:
                    raise ValueError(f'Missing skull albedo for {name}')
            elif identifier == 'prism':
                for key, suffix, scalar in [('diffuse', 'BaseColor', False), ('normal', 'Normal', False),
                                             ('emission', 'Emissive', False), ('metallic', 'Metallic', True), ('rough', 'Roughness', True)]:
                    path = folder / f'textures/Crystal_lambert1_{suffix}.png'
                    spec[key] = texture(image(path), label+'-'+key, 1024 if key in ('diffuse', 'normal') else 512, scalar)
            elif identifier == 'nova':
                spec.update(diffuse=texture(image(folder / 'textures/T_Ghost.png'), label+'-color', 1024),
                            metalness=0, roughness=0.7)
            materials.append(spec)

        records = []
        for number, mesh in enumerate(meshes):
            position = ((np.asarray(mesh.vertices).reshape(-1, 3) - center) @ rotation.T * scale).astype('<f4')
            normal = (np.asarray(mesh.normals).reshape(-1, 3) @ rotation.T).astype('<f4')
            normal /= np.maximum(np.linalg.norm(normal, axis=1, keepdims=True), 1e-8)
            uv = np.asarray(mesh.texcoords[0]).reshape(-1, 2).copy() if mesh.texcoords else np.zeros((len(position), 2))
            # Assimp normalizes glTF image coordinates to bottom-left, like FBX/Collada.
            interleaved = np.concatenate((position, normal, uv), axis=1).astype('<f4')
            indices = np.asarray(mesh.indices, dtype='<u4').reshape(-1)
            assert len(indices) % 3 == 0 and indices.max() < len(position)
            assert np.isfinite(interleaved).all()
            data = interleaved.tobytes() + indices.tobytes()
            filename = f'mesh-{number}.vmesh'; (output / filename).write_bytes(data)
            records.append({'name': mesh.name or f'mesh-{number}', 'file': filename, 'vertices': len(position),
                            'indices': len(indices), 'material': used_indices.index(mesh.material_index),
                            'sha256': hashlib.sha256(data).hexdigest()})
        catalog['collections'][identifier] = {'title': title, 'source': directory, 'meshes': records, 'materials': materials}
        print(title, sum(m['vertices'] for m in records), 'vertices /', sum(m['indices']//3 for m in records), 'triangles')
    (OUTPUT / 'catalog.json').write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('root', type=Path)
    convert(parser.parse_args().root)

