"""Bounded public-Internet transport. No credentials or response bodies in errors."""
import http.client
import ipaddress
import json
import socket
import ssl
from urllib.parse import urlsplit, urljoin
from urllib.robotparser import RobotFileParser

MAX_BODY = 6 * 1024 * 1024


def public_url(url):
    p = urlsplit(str(url))
    if p.scheme not in ('http', 'https') or not p.hostname or p.username or p.password:
        raise ValueError('Use a public http(s) job URL without embedded credentials.')
    if p.port not in (None, 80, 443):
        raise ValueError('Nonstandard ports are not supported.')
    if p.hostname.lower() in ('localhost', 'metadata.google.internal') or p.hostname.endswith(('.local', '.internal')):
        raise ValueError('Private network URLs are not allowed.')
    return p


def addresses(host, port):
    results = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    ips = sorted({r[4][0] for r in results})
    if not ips or any(not ipaddress.ip_address(ip).is_global for ip in ips):
        raise ValueError('Private network destinations are not allowed.')
    return ips


def fetch(url, headers=None, body=None, method=None, body_limit=MAX_BODY, allowed_hosts=None):
    """DNS is checked AND the connection pinned; redirects are checked individually."""
    initial = public_url(url).hostname
    for _ in range(5):
        p = public_url(url)
        if allowed_hosts is not None and p.hostname not in allowed_hosts:
            raise ValueError('Redirect is outside the selected source.')
        port = p.port or (443 if p.scheme == 'https' else 80)
        ip = addresses(p.hostname, port)[0]
        conn = http.client.HTTPConnection(p.hostname, port, timeout=20)
        sock = socket.create_connection((ip, port), timeout=20)
        conn.sock = sock
        if p.scheme == 'https':
            try:conn.sock = ssl.create_default_context().wrap_socket(sock, server_hostname=p.hostname)
            except Exception:
                conn.close();raise
        hs = {'User-Agent': 'StackJobDiscovery/0.1', 'Accept': 'application/json, text/html;q=0.9', **(headers or {})}
        if p.hostname != initial:
            hs = {k:v for k,v in hs.items() if k.lower() not in ('authorization','x-api-key','api-key')}
        payload = json.dumps(body).encode() if body is not None else None
        if payload is not None: hs['Content-Type'] = 'application/json'
        try:
            conn.request(method or ('POST' if payload else 'GET'), p.path + ('?' + p.query if p.query else ''), body=payload, headers=hs)
            response = conn.getresponse()
            status = response.status
            rh = {k.lower():v for k,v in response.getheaders()}
            if status in (301,302,303,307,308):
                if body is not None or any(k.lower() in ('authorization','authorization-key','x-api-key','api-key') for k in (headers or {})) or 'app_key=' in url: raise ValueError('Unexpected authenticated API redirect.')
                url = urljoin(url, rh.get('location',''))
                continue
            raw = response.read(body_limit + 1)
            if len(raw)>body_limit: raise ValueError('Source response exceeds the configured body limit.')
            if status not in (200,304): raise ValueError(f'Source returned HTTP {status}.')
            return {'status':status, 'headers':rh, 'url':url, 'text':raw.decode('utf-8', errors='replace')}
        finally:
            conn.close()
    raise ValueError('Too many redirects.')


def json_fetch(url, **kwargs):
    return json.loads(fetch(url, **kwargs)['text'])


def page_fetch(url, allowed_hosts=None):
    p=public_url(url)
    robots_url=f'{p.scheme}://{p.netloc}/robots.txt'
    try:
        robots=fetch(robots_url, allowed_hosts=allowed_hosts)['text']
    except ValueError as exc:
        if 'HTTP 404' not in str(exc): raise ValueError('Unable to establish crawl permission.') from None
        robots=''
    rp=RobotFileParser(); rp.parse(robots.splitlines())
    if not rp.can_fetch('StackJobDiscovery',url): raise ValueError('This site disallows automated collection.')
    return fetch(url, allowed_hosts=allowed_hosts)
