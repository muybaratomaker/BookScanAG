#!/usr/bin/env python3
"""Convert official UVDoc weights to Core ML; requires a verified upstream checkout.

Python 3.12 / torch 2.5.1+cpu / coremltools 8.3.0 / numpy 1.26.4 / Pillow 11.1.0.
No downloads at app runtime. Linux can convert, but cannot execute Core ML.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import time

CHECKPOINT_SHA256 = '7e90861b8a516eb4bc51f84bd889cb77275743d2d1d3ca8091951ec9f2b7da23'
UPSTREAM_COMMIT = '4c9b82b537057aff2526e6dd118a847cdd072e82'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('Models/UVDoc.mlpackage'))
    parser.add_argument('--reference-image', type=Path)
    args = parser.parse_args()
    import numpy as np
    import torch
    import coremltools as ct
    from PIL import Image
    torch.set_num_threads(2)
    checkpoint = args.upstream / 'model/best_model.pkl'
    actual = hashlib.sha256(checkpoint.read_bytes()).hexdigest()
    if actual != CHECKPOINT_SHA256:
        raise SystemExit('Official checkpoint SHA-256 mismatch; stop before loading.')
    spec = importlib.util.spec_from_file_location('uvdoc_upstream', args.upstream / 'model.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    model = module.UVDocnet(num_filter=32, kernel_size=5)
    state = torch.load(checkpoint, map_location='cpu', weights_only=True)
    model.load_state_dict(state['model_state'], strict=True)
    model.eval()

    class GridOnly(torch.nn.Module):
        def __init__(self, base):
            super().__init__()
            self.base = base
        def forward(self, image):
            return self.base(image)[0]

    wrapper = GridOnly(model).eval()
    # This deterministic synthetic image validates computation, not real-photo quality.
    yy, xx = np.mgrid[0:712, 0:488]
    sample = np.full((712, 488, 3), 0.92, dtype=np.float32)
    line = ((yy + 18 * (xx / 487) ** 2) % 28 < 2) & (xx > 25) & (xx < 465)
    sample[line] = 0.15
    if args.reference_image:
        sample = np.asarray(Image.open(args.reference_image).convert('RGB').resize((488, 712), Image.Resampling.BILINEAR), dtype=np.float32) / 255
    tensor = torch.from_numpy(sample.transpose(2, 0, 1).copy()).unsqueeze(0)
    start = time.perf_counter()
    with torch.no_grad():
        reference = wrapper(tensor)
        traced = torch.jit.trace(wrapper, tensor)
        traced_output = traced(tensor)
    seconds = time.perf_counter() - start
    assert reference.shape == (1, 2, 45, 31)
    assert torch.isfinite(reference).all()
    max_diff = float(torch.max(torch.abs(reference - traced_output)))
    assert max_diff < 1e-5
    args.output.parent.mkdir(parents=True, exist_ok=True)
    converted = ct.convert(
        traced,
        inputs=[ct.ImageType(name='image', shape=(1, 3, 712, 488), scale=1/255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name='grid')],
        convert_to='mlprogram', minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT32, skip_model_load=True,
    )
    converted.author = 'Tanguy Magne, Floor Verhoeven, Olga Sorkine-Hornung; BookScanAG conversion'
    converted.license = 'MIT; see Models/UVDoc-LICENSE.txt'
    converted.short_description = 'UVDoc backward sampling grid; RGB 488x712, align_corners=True, top-left origin.'
    converted.input_description['image'] = 'Upright RGB page, resized to 488x712. Pixel scaling 1/255 is in the model.'
    converted.output_description['grid'] = '1x2x45x31 backward (x,y) grid in [-1,1] source coordinates; validate before resampling.'
    converted.save(str(args.output))
    metadata = {
        'upstream': 'https://github.com/tanguymagne/UVDoc', 'commit': UPSTREAM_COMMIT,
        'checkpoint_sha256': actual, 'checkpoint_bytes': checkpoint.stat().st_size,
        'model_bytes': sum(p.stat().st_size for p in args.output.rglob('*') if p.is_file()),
        'input': [1,3,712,488], 'output': list(reference.shape),
        'torchscript_max_absolute_difference': max_diff,
        'reference_grid_min': float(reference.min()), 'reference_grid_max': float(reference.max()),
        'inference_and_tracing_seconds_linux_cpu': seconds,
        'coreml_runtime_comparison': 'NOT RUN: requires macOS or iOS',
        'reference_kind': str(args.reference_image) if args.reference_image else 'synthetic curved lines, not real book photo',
        'torch': torch.__version__, 'coremltools': ct.__version__, 'precision': 'FLOAT32',
    }
    args.output.with_suffix('.conversion.json').write_text(json.dumps(metadata, indent=2)+'\n')
    print(json.dumps(metadata, indent=2))

if __name__ == '__main__':
    main()
