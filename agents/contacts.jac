"""Import only explicitly supplied contacts. No address guessing or scraping."""
import csv;
import io;
import re;
import from agents.contracts { validate_contact }
def parse_contacts(content: str) -> list[dict[(str, any)]] {
    if (len(content) > 200000) {
        raise ValueError('Import at most 200 KB at a time.');
    }
    reader = csv.DictReader(io.StringIO(content));
    if (
        not reader.fieldnames
        or ('email' not in [x.strip().lower() for x in reader.fieldnames])
    ) {
        emails = sorted(
            `set(
                re.findall(
                    r'\b[A-Za-z0-9.!#$%&\x27*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b',
                    content
                )
            )
        );
        if (len(emails) > 200) {
            raise ValueError('Import at most 200 contacts.');
        }
        return [
            validate_contact(
                {
                    'name': email,
                    'email': email,
                    'source': content[:2000],
                    'selected': False
                }
            ) for email in emails
        ];
    }
    rows = `list(reader) as list[dict[str, any]];
    if (len(rows) > 200) {
        raise ValueError('Import at most 200 contacts at a time.');
    }
    values = [];
    for row in rows {
        row = {
            str(k).strip().lower(): v
            for (k, v) in row.items()
            if k
        };
        values.append(
            validate_contact(
                {
                    ** row,
                    'selected': False,
                    'source': (row.get('source') or 'User supplied CSV')
                }
            )
        );
    }
    return values;
}
