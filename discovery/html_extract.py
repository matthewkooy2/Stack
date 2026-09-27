"""Small explicit, fixture-testable fallback; no guessed job titles from page headers."""
from html.parser import HTMLParser
from discovery.normalize import plain

class Extractor(HTMLParser):
    def __init__(self,selectors):super().__init__();self.selectors=selectors;self.stack=[];self.result={}
    def handle_starttag(self,tag,attrs):
        attrs=dict(attrs);matched=[]
        for field,selector in self.selectors.items():
            if selector.startswith('#'):hit=attrs.get('id')==selector[1:]
            elif selector.startswith('.'):hit=selector[1:] in attrs.get('class','').split()
            else:hit=tag==selector
            if hit:matched.append(field)
        self.stack.append((tag,matched))
    def handle_endtag(self,tag):
        for i in range(len(self.stack)-1,-1,-1):
            if self.stack[i][0]==tag:self.stack=self.stack[:i];break
    def handle_data(self,text):
        for _,fields in self.stack:
            for f in fields:self.result[f]=self.result.get(f,'')+text+' '

def extract(text,source,url):
    selectors=source.get('selectors')
    if not selectors:return []
    p=Extractor(selectors);p.feed(text);job={k:plain(v) for k,v in p.result.items()}
    if not job.get('title') or not job.get('description'):return []
    return [{**job,'company':job.get('company') or source['name'],'url':url,'employer_domain':source.get('domain',''),'country':source.get('country','Unknown')}]
