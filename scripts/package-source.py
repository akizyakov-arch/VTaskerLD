"""Create a source-only update; excludes databases, recordings, models and build caches."""
from pathlib import Path
import hashlib
import stat
import sys
import zipfile
repo=Path(__file__).resolve().parents[1]
output=Path(sys.argv[1]) if len(sys.argv)>1 else repo.parent/'artifacts'/'VTASK-web-panel-source.zip'
output.parent.mkdir(parents=True,exist_ok=True)
files=[repo/name for name in ['.gitignore','Cargo.toml','Cargo.lock','rust-toolchain.toml','README.md']]
for directory in ['src','migrations','native','scripts','tests','web','docs']:
    for path in (repo/directory).rglob('*'):
        if path.is_file() and not any(part in {'__pycache__','.build','.swiftpm','target','node_modules'} for part in path.relative_to(repo).parts):
            files.append(path)
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(files):archive.write(path,'VTaskerLD/'+str(path.relative_to(repo)))
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    assert len(archive.namelist())==len(files)
    for path in files:
        name='VTaskerLD/'+str(path.relative_to(repo))
        assert archive.read(name)==path.read_bytes()
    for name in ['scripts/setup-macos.sh','scripts/start-macos.sh','tests/fixtures/capture.py']:
        assert archive.getinfo('VTaskerLD/'+name).external_attr>>16 & stat.S_IXUSR
    assert not any('/.git/' in name or '/.vtracker/' in name or '/target/' in name or name.endswith(('.sqlite3','.sqlite3-wal','.sqlite3-shm','.onnx','.bin')) for name in archive.namelist())
checksum=hashlib.sha256(output.read_bytes()).hexdigest()
output.with_name(output.name+'.sha256').write_text(checksum+'  '+output.name+'\n')
print(f'{output}: {len(files)} files, {output.stat().st_size} bytes, SHA-256 {checksum}')
