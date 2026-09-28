"""Read the public source a user supplied; never discover addresses or scrape LinkedIn."""
import from urllib.parse { urlsplit }
import from discovery.transport { page_fetch }
import from discovery.normalize { plain }
def contact_source(contact: dict[str, any]) -> dict[str, any] {
    url = contact.get('source_url', '');
    if not url {
        return {
            'summary': contact.get('relationship', ''),
            'text': contact.get('source', ''),
            'url': ''
        };
    }
    host = (urlsplit(url).hostname or '').lower();
    if ((host == 'linkedin.com') or host.endswith('.linkedin.com')) {
        return {
            'summary': 'Use your supplied LinkedIn text or open the profile yourself.',
            'text': contact.get('source', ''),
            'url': url,
            'manual': True
        };
    }
    try {
        page = page_fetch(url, allowed_hosts={host});
        text = plain(page['text'])[:12000];
        return {
            'summary': 'Read the public source you supplied.',
            'text': text,
            'url': url
        };
    } except ValueError {
        return {
            'summary': 'The supplied source was unavailable for automated reading.',
            'text': contact.get('source', ''),
            'url': url
        };
    }
}
