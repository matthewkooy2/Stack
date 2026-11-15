"""Select a bundled, uniformly cropped photo from explicit posting locations."""
import hashlib
import json
from pathlib import Path
import re


def _key(text):
    return ' '.join(text.casefold().replace('.', '').split())


def _index():
    records = json.loads(Path(__file__).with_name('job_photos.json').read_text('utf-8'))
    qualified, bare, boards, nature = {}, {}, {}, []
    for photo, record in records.items():
        if 'names' not in record:
            nature.append(photo)
            continue
        countries = {_key(c) for c in record['countries']}
        if 'us' in countries:
            countries.update(('usa', 'united states', 'united states of america'))
        for board, names in record.get('board_names', {}).items():
            boards.update({(board, name): photo for name in names})
        for name in map(_key, record['names']):
            bare[name] = (photo, countries)
            for region in map(_key, record['regions']):
                qualified[f'{name}, {region}'] = photo
                for country in countries:
                    qualified[f'{name}, {region}, {country}'] = photo
            # 'New York, US' could refer to the state. 'New York, NY' names the city.
            if name != 'new york':
                for country in countries:
                    qualified[f'{name}, {country}'] = photo
    return qualified, bare, boards, tuple(sorted(nature))


QUALIFIED, BARE, BOARDS, NATURE = _index()
COUNTRIES = set().union(*(countries for _, countries in BARE.values()))
# These names themselves identify a city, even without a separate country field.
UNQUALIFIED = {'singapore', 'new york city', 'nyc', 'mexico city', 'cdmx',
               'taipei city', 'washington, dc', 'washington dc', 'washington, district of columbia'}
NO_PLACE = {'', 'hybrid', 'in-office', 'in office', 'on-site', 'onsite', 'on site',
            'distributed', 'in-person', 'location not listed', 'n/a', 'na', 'unknown', 'tbd', 'location'}


def _city(label, country, board=''):
    label = _key(label)
    label = re.sub(r'^(?:hybrid|on-site|in-office)\s+[-–—]\s+', '', label)
    if label in QUALIFIED:
        return QUALIFIED[label]
    if label in BARE and label != 'new york':
        photo, countries = BARE[label]
        if country in countries or (country in ('', 'unknown') and
                                    (label in UNQUALIFIED or (board, label) in BOARDS)):
            return photo
    return None


def posting_photo(job, location_excerpt='', preferred_location=''):
    country = _key(job.get('country') or '')
    labels = job.get('locations') or [job.get('location') or '']
    parts = [part.strip() for label in labels for part in re.split(r'[;|•]|\s+or\s+', label, flags=re.I)
             if _key(part) not in NO_PLACE]
    board = job.get('source_id') or ''
    # A country label may corroborate an explicit city in a role-location statement.
    scope_countries = None
    if location_excerpt and (not parts or (len(parts) == 1 and _key(parts[0]) in COUNTRIES)):
        if parts:
            country = _key(parts[0])
            scope_countries = {photo for photo, countries in BARE.values() if country in countries}
        statement = re.sub(r'^this (?:role|position) is based in (?:our )?', '', location_excerpt, flags=re.I)
        parts = re.split(r'[;|•]|\s+or\s+', statement.removesuffix('.'), flags=re.I)
    cities = {_city(part.strip(), country, board) for part in parts}
    if scope_countries is not None and not cities <= scope_countries:
        cities = set()
    if len(cities) == 1 and None not in cities:
        return next(iter(cities))
    if preferred_location:
        preferred = _city(preferred_location, '') or BARE.get(_key(preferred_location), (None,))[0]
        if preferred and preferred in cities:
            return preferred
    seed = job.get('id') or job.get('url') or job.get('title') or ''
    digest = hashlib.sha256(seed.encode('utf-8')).digest()
    return NATURE[int.from_bytes(digest[:4], 'big') % len(NATURE)]

