#!/usr/bin/env python3
"""Isolated deterministic native Range checks. Never touches the user's replay cache."""
import argparse, hashlib, http.server, json, pathlib, secrets, subprocess, tempfile, threading, time, urllib.request, urllib.error

def bencode(value):
    if isinstance(value,int): return b'i'+str(value).encode()+b'e'
    if isinstance(value,str): value=value.encode()
    if isinstance(value,bytes): return str(len(value)).encode()+b':'+value
    if isinstance(value,list): return b'l'+b''.join(map(bencode,value))+b'e'
    return b'd'+b''.join(bencode(k)+bencode(v) for k,v in sorted(value.items()))+b'e'

def run(args):
    payload=(b'PeerStream deterministic original native range fixture.\n'*20000)[:1024*1024]
    seed_allowed = threading.Event()
    payload_requests = []
    class Seed(http.server.BaseHTTPRequestHandler):
        def log_message(self,*_): pass
        def do_GET(self):
            if self.path!='/fixture.mp4': self.send_error(404); return
            payload_requests.append(self.headers.get('Range'))
            if not seed_allowed.wait(timeout=30): self.send_error(503); return
            start,end=0,len(payload)-1
            if self.headers.get('Range'):
                span=self.headers['Range'].split('=')[1].split('-');start=int(span[0]);end=int(span[1] or end)
                self.send_response(206);self.send_header('Content-Range',f'bytes {start}-{end}/{len(payload)}')
            else: self.send_response(200)
            self.send_header('Content-Length',str(end-start+1));self.send_header('Accept-Ranges','bytes');self.end_headers()
            self.wfile.write(payload[start:end+1])
    seed=http.server.ThreadingHTTPServer(('127.0.0.1',0),Seed)
    threading.Thread(target=seed.serve_forever,daemon=True).start()
    piece=256*1024
    info={b'length':len(payload),b'name':b'fixture.mp4',b'piece length':piece,b'pieces':b''.join(hashlib.sha1(payload[i:i+piece]).digest() for i in range(0,len(payload),piece))}
    identity=hashlib.sha1(bencode(info)).hexdigest()
    torrent=bencode({b'info':info,b'url-list':[f'http://127.0.0.1:{seed.server_port}/fixture.mp4']})
    args.temp_parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='service-native-',dir=args.temp_parent) as root:
        token=secrets.token_hex(32)
        log=pathlib.Path(root)/'stderr.log'
        def launch():
            process=subprocess.Popen([str(args.binary),'--root',root,'--native',str(args.library)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log.open('ab'),text=True)
            process.stdin.write(json.dumps({'token':token})+'\n');process.stdin.flush()
            line=process.stdout.readline()
            if not line:
                raise RuntimeError(log.read_text()[-3000:])
            ready=json.loads(line)
            return process,ready
        process,ready=launch()
        endpoint=f'http://127.0.0.1:{ready["port"]}'
        def req(path,body=None,authorized=True,origin=None):
            headers={}
            if authorized:headers['Authorization']='Bearer '+token
            if body is not None:headers['Content-Type']='application/json'
            if origin:headers['Origin']=origin
            request=urllib.request.Request(endpoint+path,data=None if body is None else json.dumps(body).encode(),headers=headers)
            try:
                with urllib.request.urlopen(request,timeout=95) as response:return response.status,json.load(response)
            except urllib.error.HTTPError as error:return error.code,json.load(error) if path == "/v1/command" else None
        def command(op,**data):
            code,result=req('/v1/command',{'op':op,'args':{'instance':ready['instance'],**data}})
            assert code==200,(op,code,result)
            return result.get('data')
        try:
            assert req('/v1/health',authorized=False)[0]==401
            assert req('/v1/health',origin='https://example.com')[0]==401
            assert req('/v1/command',{'op':'health','args':{'instance':'stale'}})[0]==422
            assert req('/v1/command',{'op':'cacheRemove','args':{'cacheKey':'../../bad'}})[0]==422
            # A duplicate owner is rejected even while the original process is idle.
            duplicate=subprocess.Popen([str(args.binary),'--root',root,'--native',str(args.library)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
            duplicate.communicate(json.dumps({'token':token})+'\n',timeout=10)
            assert duplicate.returncode!=0
            assert req('/v1/health')[1]['capabilities']['cachedMetadataResume'] is True
            miss_code, miss = req('/v1/command', {'op':'add','args':{'instance':ready['instance'],'requestId':'cache-miss','cacheKey':identity,'resumeOnly':True}})
            assert miss_code == 422 and miss['code'] == 'cache_miss', (miss_code, miss)
            for round_number in range(2):
                seed_allowed.clear()
                payload_requests.clear()
                session=command('add',requestId=f'round-{round_number}',cacheKey=identity,torrent=list(torrent))['session']
                assert command('add',requestId=f'round-{round_number}',cacheKey=identity,torrent=list(torrent))['session']==session
                deadline=time.monotonic()+20
                files=[]
                while not files and time.monotonic()<deadline:
                    files=command('files',session=session);time.sleep(.1)
                assert files and files[0]['size']==len(payload)
                time.sleep(1)
                assert payload_requests == [], ('metadata-only requested payload', payload_requests)
                assert command('snapshot', session=session)['downloadedBytes'] == 0
                command('persist')
                state = (pathlib.Path(root)/'payload'/identity/'resume.dat').read_bytes()
                assert b'11:upload_modei0e' in state, 'transient guard leaked into persisted policy'
                assert payload_requests == [], 'persistence changed live metadata-only mode'
                record={'cacheKey':identity,'source':{'id':'fixture'},'file':{'index':0,'name':'fixture.mp4','size':len(payload),'isStreamable':True},'complete':True,'byteSize':len(payload),'lastUsedAt':0,'timeBytePoints':[]}
                command('cacheRecord',**record)
                assert command('cacheIndex')['entries'][0]['complete'] is False
                seed_allowed.set()
                snapshot=command('start',session=session,fileIndex=0)
                url=snapshot['stream']['url']
                assert len(url.rsplit('/',1)[-1])>=32
                def read_range(start,end):
                    request=urllib.request.Request(url,headers={'Range':f'bytes={start}-{end}'})
                    with urllib.request.urlopen(request,timeout=70) as response:
                        assert response.status==206
                        assert response.read()==payload[start:end+1]
                read_range(0,1023);read_range(len(payload)-1024,len(payload)-1)
                from concurrent.futures import ThreadPoolExecutor
                with ThreadPoolExecutor(2) as pool:list(pool.map(lambda offset:read_range(offset,offset+511),[4096,8192]))
                try:urllib.request.urlopen(url.rsplit('/',1)[0]+'/invalid',timeout=5);raise AssertionError('unguarded stream')
                except urllib.error.HTTPError as error:assert error.code==403
                command('profile',lowMemory=True)
                assert req('/v1/health')[1]['pieceCacheBudgetBytes']==64*1024*1024
                command('cacheRecord',**record)
                command('cachePin',cacheKey=identity,pinned=True)
                command('release',session=session)
                # The second round exercises source.torrent when resume data is absent.
                if round_number == 1:
                    (pathlib.Path(root)/'payload'/identity/'resume.dat').unlink()
                restored = command('add',requestId=f'cached-{round_number}',cacheKey=identity,resumeOnly=True)['session']
                assert command('files',session=restored)
                command('release',session=restored)
                command('cachePreferences' ,maxCacheBytes=1)
                assert command('cachePrune')['overBudget'] is True
                assert command('cacheIndex')['entries'][0]['pinned'] is True
                command('cachePin',cacheKey=identity,pinned=False)
                command('cachePrune')
                assert command('cacheIndex')['entries']==[]
                command('cacheClear')
                assert list((pathlib.Path(root)/'payload').iterdir())==[]
                print(json.dumps({'pass':round_number+1,'range':206,'tailAndConcurrentReads':True,'bridge':req('/v1/health')[1]['bridgeVersion']}),flush=True)
            # EOF of the private parent lease must terminate the helper.
            process.stdin.close();process.wait(timeout=12);assert process.returncode==0
            process,ready=launch()
            assert process.poll() is None
            process.kill();process.wait(timeout=5)
            process,ready=launch()  # OS lock must be released after a crash.
            process.stdin.close();process.wait(timeout=12);assert process.returncode==0
            print('Native service authentication, ownership, Range, reset and crash/restart checks passed.',flush=True)
        finally:
            if process.poll() is None:process.kill();process.wait(timeout=5)
    seed_allowed.set()
    seed.shutdown()

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--binary',type=pathlib.Path,required=True);p.add_argument('--library',type=pathlib.Path,required=True);p.add_argument('--temp-parent',type=pathlib.Path,required=True)
    run(p.parse_args())
