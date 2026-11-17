#!/usr/bin/env python3
"""Deterministic vector fixture. Does not perform speaker identification."""
import json
from pathlib import Path
import sys
model=Path(sys.argv[1]).read_bytes()
values=[0,1,0,0] if model==b'model-b' else [1,0,0,0]
if model==b'invalid': values=[0,0,0,0]
Path(sys.argv[3]).write_text(json.dumps({'embedding':values}))
