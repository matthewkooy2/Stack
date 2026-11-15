"""Resolve a Jobs page against the reviewed employer directory in the catalog database."""
import json


def employer_logos(store, cards: list[dict]) -> dict[str, str]:
    def keys(card):
        domain = (card.get('employer_domain') or '').strip().lower().removeprefix('www.').rstrip('.')
        board = card.get('source_id') or ''
        return ('domain:' + domain if domain else '', 'board:' + board if board else '')

    wanted = {key for card in cards for key in keys(card) if key}
    if not wanted or not store.rows("SELECT to_regclass('public.stack_employer_brand_key') IS NOT NULL", {})[0][0]:
        return {}
    rows = store.rows("""
        SELECT k.lookup_key, b.domain, replace(encode(b.logo_png, 'base64'), chr(10), '')
        FROM public.stack_employer_brand_key k
        JOIN public.stack_employer_brand b ON b.domain = k.brand_domain
        WHERE k.lookup_key IN (SELECT jsonb_array_elements_text(CAST(:wanted AS jsonb)))
    """, {'wanted': json.dumps(sorted(wanted))})
    mapped = {key: domain for key, domain, _ in rows}
    images = {domain: png for _, domain, png in rows}
    logos = {}
    for card in cards:
        domain_key, board_key = keys(card)
        # A known board may fill a missing domain. A different or unreviewed
        # explicit employer on that board must never inherit its brand.
        brand = mapped.get(domain_key) if domain_key else mapped.get(board_key)
        if brand and mapped.get(board_key, brand) == brand:
            card['employer_brand'] = brand
            if brand not in logos:
                logos[brand] = images[brand]
    return logos
