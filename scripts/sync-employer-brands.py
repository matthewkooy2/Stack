"""Emit an atomic psql migration for the reviewed employer directory."""
import base64
import json
from pathlib import Path
import re
import struct
import sys


def migration():
    discovery = Path(__file__).resolve().parents[1] / 'discovery'
    records = json.loads((discovery / 'employer_brands.json').read_text('utf-8'))
    brands, keys = {}, {}
    for record in records:
        domain = record['domain']
        if not re.fullmatch(r'[a-z0-9-]+(?:\.[a-z0-9-]+)+', domain) or domain in brands:
            raise ValueError(f'Invalid or duplicate brand domain {domain}')
        png = (discovery / 'brand_logos' / (domain + '.png')).read_bytes()
        if (png[:8] != b'\x89PNG\r\n\x1a\n' or struct.unpack('>II', png[16:24]) != (120, 120)
                or len(png) > 32768 or not record['artwork_source'].startswith('https://')):
            raise ValueError(f'Unreviewable asset for {domain}')
        brands[domain] = dict(domain=domain, name=record['name'], artwork_source=record['artwork_source'],
                              png=base64.b64encode(png).decode('ascii'))
        if domain not in record['domains']:
            raise ValueError(f'Missing primary domain {domain}')
        for key in ['domain:' + d for d in record['domains']] + ['board:' + b for b in record['boards']]:
            if key in keys:
                raise ValueError(f'Duplicate employer mapping {key}')
            keys[key] = domain
    if not brands:
        raise ValueError('Employer directory is empty')
    # Only base64 enters SQL literals. The complete release is validated before any SQL is emitted.
    def payload(value):
        data = base64.b64encode(json.dumps(value).encode()).decode('ascii')
        return f"convert_from(decode('{data}', 'base64'), 'UTF8')::jsonb"
    return f"""\u005cset ON_ERROR_STOP on
BEGIN;
CREATE TABLE IF NOT EXISTS public.stack_employer_brand (
    domain text PRIMARY KEY, name text NOT NULL, artwork_source text NOT NULL,
    logo_png bytea NOT NULL CHECK (octet_length(logo_png) BETWEEN 1 AND 32768)
);
CREATE TABLE IF NOT EXISTS public.stack_employer_brand_key (
    lookup_key text PRIMARY KEY, brand_domain text NOT NULL REFERENCES public.stack_employer_brand(domain) ON DELETE CASCADE
);
LOCK TABLE public.stack_employer_brand, public.stack_employer_brand_key IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE incoming_brand ON COMMIT DROP AS
    SELECT domain, name, artwork_source, decode(png, 'base64') AS logo_png FROM
    jsonb_to_recordset({payload(list(brands.values()))}) AS r(domain text,name text,artwork_source text,png text);
CREATE TEMP TABLE incoming_key ON COMMIT DROP AS
    SELECT key AS lookup_key, value AS brand_domain FROM jsonb_each_text({payload(keys)});
INSERT INTO public.stack_employer_brand AS b SELECT * FROM incoming_brand
    ON CONFLICT (domain) DO UPDATE SET name=excluded.name, artwork_source=excluded.artwork_source, logo_png=excluded.logo_png
    WHERE (b.name,b.artwork_source,b.logo_png) IS DISTINCT FROM (excluded.name,excluded.artwork_source,excluded.logo_png);
INSERT INTO public.stack_employer_brand_key AS k SELECT * FROM incoming_key
    ON CONFLICT (lookup_key) DO UPDATE SET brand_domain=excluded.brand_domain WHERE k.brand_domain<>excluded.brand_domain;
DELETE FROM public.stack_employer_brand_key k WHERE NOT EXISTS (SELECT FROM incoming_key i WHERE i.lookup_key=k.lookup_key);
DELETE FROM public.stack_employer_brand b WHERE NOT EXISTS (SELECT FROM incoming_brand i WHERE i.domain=b.domain);
COMMIT;
"""


if __name__ == '__main__':
    sys.stdout.write(migration())
