"""Pull notifications with deployment ADC, then acknowledge only persisted wakeups."""
import hashlib;
import os;
import re;
import from agents.security { http }
def notifications() -> dict[str, any] | None {
    subscription = os.environ.get('GOOGLE_GMAIL_SUBSCRIPTION', '');
    if not subscription {
        return None;
    }
    if not re.fullmatch(
        r'projects/[a-z0-9-]+/subscriptions/[A-Za-z0-9._~-]+', subscription
    ) {
        raise ValueError('Invalid Gmail notification subscription.');
    }
    import google.auth;
    import from google.auth.transport.requests { Request }
    (credentials, _) = google.auth.default(
        scopes=['https://www.googleapis.com/auth/pubsub']
    ) as tuple[any, str | None];
    credentials.refresh(Request());
    headers = {
        'Authorization': ('Bearer ' + credentials.token),
        'Content-Type': 'application/json'
    };
    base = 'https://pubsub.googleapis.com/v1/' + subscription;
    result = http((base + ':pull'), {'maxMessages': 100}, headers, timeout=15);
    messages = result.get('receivedMessages', []);
    if not messages {
        return None;
    }
    identifiers = sorted(m['message']['messageId'] for m in messages);
    return {
        'key': hashlib.sha256('|'.join(identifiers).encode()).hexdigest(),
        'ack_ids': [m['ackId'] for m in messages],
        'base': base,
        'headers': headers
    };
}
def acknowledge(batch: dict[str, any]) {
    http(
        (batch['base'] + ':acknowledge'), {'ackIds': batch['ack_ids']}, batch['headers']
    );
}
