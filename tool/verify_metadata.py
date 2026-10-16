#!/usr/bin/env python3
"""Snapshot small app metadata before native verification; check for mutations afterwards.
Retain the snapshot for manual recovery if anything changed. Never overwrite newer data.
"""
import argparse,hashlib,json,pathlib,shutil,time
p=argparse.ArgumentParser();p.add_argument('action',choices=['snapshot','check']);p.add_argument('root',type=pathlib.Path);p.add_argument('--snapshot',type=pathlib.Path);args=p.parse_args()
if args.action=='snapshot':
    folder=args.root/'temp'/('verification-metadata-'+str(time.time_ns()));folder.mkdir(parents=True)
    hashes={}
    for file in (args.root/'data').glob('*.json'):
        hashes[file.name]=hashlib.sha256(file.read_bytes()).hexdigest();shutil.copy2(file,folder/file.name)
    (folder/'manifest.json').write_text(json.dumps(hashes));print(folder)
else:
    hashes=json.loads((args.snapshot/'manifest.json').read_text());changed=[]
    for name,digest in hashes.items():
        file=args.root/'data'/name
        if not file.exists() or hashlib.sha256(file.read_bytes()).hexdigest()!=digest or file.stat().st_mtime_ns!=(args.snapshot/name).stat().st_mtime_ns:changed.append(name)
    changed.extend(sorted(file.name for file in (args.root/'data').glob('*.json') if file.name not in hashes))
    print(json.dumps({'changedFiles':changed,'snapshotRetained':str(args.snapshot)}));raise SystemExit(bool(changed))
