"""Public official repo metadata download only. No repo or package installation."""
import gzip,hashlib,json,pathlib,subprocess,urllib.request
HERE=pathlib.Path(__file__).resolve().parent
BASE='https://download.docker.com/linux/ubuntu/'
def fetch(path):
    with urllib.request.urlopen(BASE+path,timeout=35) as response:return response.read(32*1024*1024)
key=fetch('gpg')
(HERE/'docker-repository.asc').write_bytes(key)
text=gzip.decompress(fetch('dists/noble/stable/binary-amd64/Packages.gz')).decode()
wanted={'docker-ce','docker-ce-cli','containerd.io','docker-buildx-plugin'}
chosen={}
for paragraph in text.split('\n\n'):
    fields={}
    for line in paragraph.splitlines():
        if line and not line.startswith((' ','\t')) and ': ' in line:
            name,value=line.split(': ',1);fields[name]=value
    name=fields.get('Package')
    if name not in wanted or fields.get('Architecture')!='amd64':continue
    if name not in chosen or subprocess.run(['/usr/bin/dpkg','--compare-versions',fields['Version'],'gt',chosen[name]['version']]).returncode==0:
        chosen[name]={'version':fields['Version'],'filename':fields['Filename'],'sha256':fields['SHA256'],'sizeBytes':int(fields['Size'])}
assert set(chosen)==wanted and chosen['docker-ce']['version']==chosen['docker-ce-cli']['version']
result={'architecture':'amd64','ubuntuCodename':'noble','officialRepository':BASE,
        'keySha256':hashlib.sha256(key).hexdigest(),'packages':chosen,
        'metadataFetchedOnly':True,'dependenciesInstalled':False}
(HERE/'docker-package-manifest.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'metadataFetchedOnly':True,'versions':{k:v['version'] for k,v in chosen.items()},
                  'packageDownloadBytes':sum(v['sizeBytes'] for v in chosen.values()),'dependenciesInstalled':False}))
