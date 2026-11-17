"""Synthesize one VTASK reply locally with a Piper voice."""
import sys
from pathlib import Path

import sherpa_onnx

model_dir, input_file, output_file = map(Path, sys.argv[1:])
model_name = model_dir.name.removeprefix("vits-piper-")
config = sherpa_onnx.OfflineTtsConfig(
    model=sherpa_onnx.OfflineTtsModelConfig(
        vits=sherpa_onnx.OfflineTtsVitsModelConfig(
            model=str(model_dir / f"{model_name}.onnx"),
            tokens=str(model_dir / "tokens.txt"),
            data_dir=str(model_dir / "espeak-ng-data"),
        ),
        num_threads=2,
        provider="cpu",
    )
)
if not config.validate():
    raise RuntimeError("Invalid Piper model configuration")
audio = sherpa_onnx.OfflineTts(config).generate(input_file.read_text(encoding="utf-8"), sid=0)
if not audio.samples or not sherpa_onnx.write_wave(str(output_file), audio.samples, audio.sample_rate):
    raise RuntimeError("Piper did not produce audio")
