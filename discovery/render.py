"""Opt-in JS rendering. Every HTTP request goes through the pinned public transport."""
from urllib.parse import urlsplit
from discovery.transport import fetch, page_fetch

def render_page(url, allowed_hosts):
    # Check initial robots policy before creating a browser.
    page_fetch(url)
    if urlsplit(url).hostname not in allowed_hosts:raise ValueError('Browser host has not been approved.')
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        raise ValueError('Browser rendering requires the optional pinned Playwright runtime.') from None
    with sync_playwright() as p:
        browser=p.chromium.launch(headless=True)
        context=browser.new_context(service_workers='block',accept_downloads=False)
        count=[0]
        def route(request_route):
            req=request_route.request;count[0]+=1
            if count[0]>80 or req.method!='GET' or urlsplit(req.url).hostname not in allowed_hosts:
                request_route.abort();return
            try:
                response=fetch(req.url)
                headers={k:v for k,v in response['headers'].items() if k not in ('content-encoding','content-length','transfer-encoding')}
                request_route.fulfill(status=response['status'],headers=headers,body=response['text'])
            except Exception:request_route.abort()
        context.route('**/*',route)
        if hasattr(context,'route_web_socket'):context.route_web_socket('**/*',lambda ws:ws.close())
        page=context.new_page()
        try:
            page.goto(url,wait_until='domcontentloaded',timeout=30000)
            page.wait_for_timeout(1500)
            return {'text':page.content(),'url':page.url,'status':200,'headers':{}}
        finally:browser.close()
