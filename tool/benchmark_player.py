#!/usr/bin/env python3
"""Run native player checks and sample *all* owned app/service processes.
RSS includes shared pages: summed RSS is diagnostic, not physical-footprint proof.
"""
import argparse, hashlib, json, pathlib, re, shutil, subprocess, threading, time
p=argparse.ArgumentParser();p.add_argument('--fixture',required=True);p.add_argument('--storage-root',type=pathlib.Path);p.add_argument('--service',action='store_true');p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--cycles',type=int,default=0);p.add_argument('--soak-minutes',type=int,default=0);p.add_argument('--cold',action='store_true');p.add_argument('--profile',action='store_true');p.add_argument('--torrent-cycles',action='store_true');p.add_argument('--resource-backend',choices=['native','service'],default='native');args=p.parse_args()
if args.torrent_cycles and args.soak_minutes: p.error('Run torrent churn and the local long soak separately.')
if args.resource_backend=='service' and not args.torrent_cycles: p.error('Service resource cycles require --torrent-cycles.')
command=['flutter','drive','-d','macos','--profile','--driver','tool/integration_driver.dart','--target','integration_test/default_player_test.dart'] if args.profile else ['flutter','test','-d','macos','integration_test/default_player_test.dart']
command.append('--dart-define=PEERSTREAM_PLAYER_FIXTURE='+args.fixture)
command.extend([f'--dart-define=PEERSTREAM_RESOURCE_CYCLES={args.cycles}',f'--dart-define=PEERSTREAM_SOAK_MINUTES={args.soak_minutes}'])
command.extend([f'--dart-define=PEERSTREAM_TORRENT_RESOURCE_CYCLES={str(args.torrent_cycles).lower()}',f'--dart-define=PEERSTREAM_RESOURCE_BACKEND={args.resource_backend}'])
if args.torrent_cycles:command.append('--dart-define=PEERSTREAM_RESOURCE_ONLY=true')
if args.service:command.append('--dart-define=PEERSTREAM_SERVICE_TEST=true')
if args.cold:command.append('--dart-define=PEERSTREAM_COLD_TORRENT=true')
before={};backup=None
if args.storage_root:
    # Only metadata, never large payloads; snapshots stay on the selected SSD.
    backup=args.storage_root/'temp'/('verification-metadata-'+str(time.time_ns()))
    backup.mkdir(parents=True)
    for file in (args.storage_root/'data').glob('*.json'):
        before[file.name]=hashlib.sha256(file.read_bytes()).hexdigest()
        shutil.copy2(file,backup/file.name)
samples=[];done=threading.Event()
def sample():
    while not done.wait(1):
        text=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,rss=,%cpu=,command='],text=True)
        rows=[]
        for line in text.splitlines():
            fields=line.strip().split(None,4)
            if len(fields)==5 and ('PeerStream.app/Contents/MacOS/PeerStream' in fields[4] or fields[4].split(' ')[0].endswith('/peerstream-service')):
                rows.append({'pid':int(fields[0]),'parent':int(fields[1]),'rssKiB':int(fields[2]),'cpuPercent':float(fields[3])})
        if rows:samples.append({'time':time.time(),'processes':rows})
thread=threading.Thread(target=sample,daemon=True);thread.start()
process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
metrics=[];verification=[]
args.output.parent.mkdir(parents=True,exist_ok=True)
with args.output.with_suffix('.log').open('w') as log:
    for line in process.stdout:
        log.write(line);log.flush()
        if any(marker in line for marker in ['[ResourceVerification]', '[ServiceVerification]']) and '{' in line:
            try:verification.append(json.loads(line[line.index('{'):]))
            except json.JSONDecodeError:pass
        if '[PlayerVerification]' in line and '{' in line:
            try:metrics.append(json.loads(line[line.index('{'):]))
            except json.JSONDecodeError:pass
code=process.wait();done.set();thread.join(timeout=2)
changed=[]
if args.storage_root:
    for name,digest in before.items():
        file=args.storage_root/'data'/name
        if not file.exists() or hashlib.sha256(file.read_bytes()).hexdigest()!=digest or file.stat().st_mtime_ns!=(backup/name).stat().st_mtime_ns:changed.append(name)
    changed.extend(sorted(file.name for file in (args.storage_root/'data').glob('*.json') if file.name not in before))
    if changed:code=1
    elif backup:shutil.rmtree(backup)

args.output.write_text(json.dumps({'mode':'profile' if args.profile else 'debug','exitCode':code,'changedMetadataFiles':changed,'metadataSnapshot':None if not changed else str(backup),'playerMetrics':metrics,'verification':verification,'processSamples':samples,'memoryScope':'Per-process RSS; shared pages may be counted more than once. GPU and physical footprint require separate tooling.'},indent=2))
print(json.dumps({'exitCode':code,'metrics':metrics,'samples':len(samples),'changedMetadataFiles':changed}))
raise SystemExit(code)
