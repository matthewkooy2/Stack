"""Pure egress policy plus container-netns installation. No host-chain changes."""
import ipaddress, json, subprocess
CHAIN='STACK_BROWSER_OUT'
BLOCKED=('0.0.0.0/8','10.0.0.0/8','100.64.0.0/10','127.0.0.0/8',
         '169.254.0.0/16','172.16.0.0/12','192.0.0.0/24','192.0.2.0/24',
         '192.88.99.0/24','192.168.0.0/16','198.18.0.0/15','198.51.100.0/24',
         '203.0.113.0/24','224.0.0.0/4','240.0.0.0/4')

def validate_dns(servers):
    assert servers and len(servers)<=3
    for value in servers:
        address=ipaddress.ip_address(value)
        assert address.version==4 and not address.is_loopback and not address.is_multicast and not address.is_unspecified
    return list(dict.fromkeys(servers))

def rules(dns):
    validate_dns(dns)
    result=[['-m','conntrack','--ctstate','ESTABLISHED,RELATED','-j','ACCEPT']]
    # Docker's embedded DNS is DNATed to an ephemeral local port. Match its
    # ORIGINAL tuple, permitting only DNS rather than arbitrary loopback access.
    for protocol in ('udp','tcp'):
        result.append(['-p',protocol,'-m','conntrack','--ctorigdst','127.0.0.11',
                       '--ctorigdstport','53','--ctdir','ORIGINAL','-j','ACCEPT'])
    for address in dns:
        for protocol in ('udp','tcp'):
            result.append(['-d',address+'/32','-p',protocol,'--dport','53','-j','ACCEPT'])
    for network in BLOCKED:result.append(['-d',network,'-j','REJECT'])
    result.append(['-p','tcp','--dport','443','-j','ACCEPT'])
    result.append(['-j','REJECT'])
    return result

def allowed(address,port,protocol='tcp',state='NEW',dns=('10.255.255.254',),original=None):
    """Independent, ordered specification used by offline negative tests."""
    addr=ipaddress.ip_address(address)
    if addr.version!=4:return False
    if state in ('ESTABLISHED','RELATED'):return True # Replies to authenticated host control connections.
    if protocol in ('tcp','udp') and original==('127.0.0.11',53):return True
    if str(addr) in dns and port==53 and protocol in ('tcp','udp'):return True
    if any(addr in ipaddress.ip_network(cidr) for cidr in BLOCKED):return False
    return protocol=='tcp' and port==443

def namespace_prefix(pid):
    assert isinstance(pid,int) and pid>1
    return ['/usr/bin/nsenter','--net=/proc/'+str(pid)+'/ns/net','--','/usr/sbin/iptables','-w','5']

def install(pid,dns,run):
    prefix=namespace_prefix(pid)
    # The container waits behind a gate. No browser is launched until this
    # chain exists and real denial tests pass. No chain is flushed/replaced.
    run(prefix+['-N',CHAIN],role='new_container_namespace_chain')
    for row in rules(dns):run(prefix+['-A',CHAIN,*row],role='container_namespace_rule')
    run(prefix+['-I','OUTPUT','1','-j',CHAIN],role='container_namespace_output_hook')

def denied_packets(pid,run):
    output=run(namespace_prefix(pid)+['-L',CHAIN,'-v','-n','-x'],role='container_rule_counters')
    count=0
    for line in output.splitlines():
        fields=line.split()
        if len(fields)>2 and fields[0].isdigit() and fields[2]=='REJECT':count+=int(fields[0])
    return count

PROBE=r'''
import json, os, socket, ssl, sys, pathlib
target=json.loads(sys.argv[1]);result={'uid':os.geteuid()}
try:
 if target['kind']=='positive':
  with socket.create_connection(('www.linkedin.com',443),timeout=12) as raw:
   with ssl.create_default_context().wrap_socket(raw,server_hostname='www.linkedin.com') as sock: result['connected']=bool(sock.version())
 else:
  family=socket.AF_INET6 if ':' in target['address'] else socket.AF_INET
  with socket.socket(family,socket.SOCK_STREAM) as sock:
   sock.settimeout(3);sock.connect((target['address'],target['port']));result['connected']=True
except Exception as e:result.update(connected=False,errorType=type(e).__name__)
print(json.dumps(result))
'''

def negative_targets(gateway):
    return [('docker_gateway_api',gateway,8000),('docker_gateway_database',gateway,5432),
            ('private_10','10.0.0.1',443),('private_172','172.16.0.1',443),
            ('private_192','192.168.0.1',443),('metadata','169.254.169.254',80),
            ('tailnet','100.100.100.100',443),('container_loopback','127.0.0.1',8011),
            ('public_http_denied','1.1.1.1',80)]

def prove(container,pid,gateway,run):
    evidence=[]
    for name,address,port in negative_targets(gateway):
        before=denied_packets(pid,run)
        raw=run(['/usr/bin/docker','exec','--user','pwuser',container,'/usr/local/bin/python3','-c',PROBE,
                 json.dumps({'kind':'negative','address':address,'port':port})],role='negative_container_network_probe',timeout=20)
        result=json.loads(raw)
        after=denied_packets(pid,run)
        assert result['uid']!=0 and not result['connected'] and after>before, 'A denied connection was not proven by a kernel counter'
        evidence.append({'targetClass':name,'blocked':True,'kernelRejectCounterIncreased':True})
    for address in ('::1','fd00::1'):
        result=json.loads(run(['/usr/bin/docker','exec','--user','pwuser',container,'/usr/local/bin/python3','-c',PROBE,
                             json.dumps({'kind':'negative','address':address,'port':8011})],role='ipv6_disabled_probe',timeout=20))
        assert not result['connected']
        evidence.append({'targetClass':'ipv6_disabled','blocked':True})
    result=json.loads(run(['/usr/bin/docker','exec','--user','pwuser',container,'/usr/local/bin/python3','-c',PROBE,
                         json.dumps({'kind':'positive'})],role='public_linkedin_tls_probe',timeout=25))
    assert result['uid']!=0 and result['connected'], 'Public HTTPS/DNS is not usable'
    return {'negativeProbes':evidence,'publicLinkedInTlsAllowed':True,'realContainerProbesPassed':True}
