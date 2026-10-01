"""Choose a subnet from read-only route metadata; create no network."""
import ipaddress,json,pathlib
HERE=pathlib.Path(__file__).resolve().parent
workspace=HERE.parent
host=json.loads((workspace/'browser-readonly-host-metadata.json').read_text())
windows=json.loads((workspace/'browser-windows-route-prefixes.json').read_text(encoding='utf-8-sig'))
linux=json.loads(host['routes']['output'])
prefixes=[]
for value in windows+[row.get('dst','default') for row in linux]:
    if value=='default':continue
    try:network=ipaddress.ip_network(value,strict=False)
    except ValueError:continue
    if network.version==4 and network.prefixlen>0:prefixes.append(network)
chosen=None
for value in ('172.30.254.0/29','172.31.254.0/29','10.253.254.0/29','192.168.253.0/29'):
    candidate=ipaddress.ip_network(value)
    if not any(candidate.overlaps(existing) for existing in prefixes):chosen=candidate;break
assert chosen is not None,'No reviewed candidate avoids existing routes'
import browser_policy
dns=browser_policy.validate_dns(host['dnsServers'])
data={'networkName':'stack-browser-egress','bridgeName':'br-stackbr','subnet':str(chosen),
      'gateway':str(chosen.network_address+1),'browserAddress':str(chosen.network_address+2),
      'probeAddress':str(chosen.network_address+3),'dnsServers':dns,'ipv6Enabled':False,
      'allExistingWindowsAndLinuxNondefaultRoutesChecked':True,
      'newDnsProviderIntroduced':False,'networkCreated':False}
(HERE/'network-plan.json').write_text(json.dumps(data,indent=2)+'\n')
print(json.dumps({k:v for k,v in data.items() if k!='dnsServers'}))
