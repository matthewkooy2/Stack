"""Content-free Expo pushes. Tickets are acceptance; receipts confirm provider handoff."""
import os;
import from agents.security { http }

with entry {
    LEASE_SECONDS = 120;
    MAX_SEND_ATTEMPTS = 3;
    MAX_RECEIPT_ATTEMPTS = 12;
    RECEIPT_DELAY = 900;
    RECEIPT_DEADLINE = 23 * 3600;
    ERRORS = {'DeviceNotRegistered', 'MessageRateExceeded', 'MessageTooBig',
        'MismatchSenderId', 'InvalidCredentials'};
}

def headers() -> dict[str, str] {
    secret = os.environ.get('EXPO_ACCESS_TOKEN', '');
    if not secret { raise ValueError('Remote notifications require the deployment push credential.'); }
    return {'Authorization': 'Bearer ' + secret, 'Content-Type': 'application/json'};
}

def provider_result(value: any, receipt: bool = False) -> dict[str, any] {
    if not isinstance(value, dict) { return {'state': 'uncertain', 'error': 'InvalidResponse'}; }
    if value.get('status') == 'ok' {
        if receipt { return {'state': 'delivered'}; }
        ticket = value.get('id');
        if isinstance(ticket, str) and ticket and len(ticket) <= 200 {
            return {'state': 'accepted', 'ticket': ticket};
        }
        return {'state': 'uncertain', 'error': 'InvalidResponse'};
    }
    details = value.get('details', {});
    code = details.get('error') if isinstance(details, dict) else '';
    if value.get('status') != 'error' { return {'state': 'uncertain', 'error': 'InvalidResponse'}; }
    return {'state': ('retry_send' if receipt else 'retry') if code == 'MessageRateExceeded' else 'failed',
        'error': code if code in ERRORS else 'ProviderRejected'};
}

def transport_error(exc: Exception, receipt: bool) -> dict[str, any] {
    # A timeout or broken connection might have queued the push. Only explicit
    # rate limits/server rejection retry sending; receipt reads are safe to retry.
    message = str(exc);
    retry = any(('HTTP ' + str(code) + ')') in message for code in [429, 500, 502, 503, 504]);
    return {'state': 'retry' if receipt or retry else 'uncertain',
        'error': 'ProviderUnavailable' if retry else 'TransportUncertain'};
}

def deliver(device: str, notice: dict[str, any]) -> dict[str, any] {
    try { auth = headers(); }
    except ValueError { return {'state': 'failed', 'error': 'MissingCredential'}; }
    try {
        result = http('https://exp.host/--/api/v2/push/send', {
            'to': device, 'title': 'Stack', 'body': 'An agent task needs your attention.',
            'data': {'user_id': notice['owner'], 'target_type': 'agent', 'target_id': notice['run_id']},
            'sound': 'default'
        }, auth, timeout=30);
        return provider_result(result.get('data'));
    } except Exception as exc { return transport_error(exc, False); }
}

def receipt(ticket: str) -> dict[str, any] {
    try {
        result = http('https://exp.host/--/api/v2/push/getReceipts', {'ids': [ticket]}, headers(), timeout=30);
        data = result.get('data');
        if not isinstance(data, dict) { return {'state': 'retry', 'error': 'InvalidResponse'}; }
        if ticket not in data { return {'state': 'pending'}; }
        return provider_result(data[ticket], True);
    } except Exception as exc { return transport_error(exc, True); }
}

def new_delivery(key: str) -> dict[str, any] {
    return {'key': key, 'state': 'queued', 'attempts': 0, 'receipt_attempts': 0,
        'ticket': '', 'accepted_at': 0.0, 'due_at': 0.0, 'lease': '', 'lease_until': 0.0,
        'error': '', 'last_lease': '', 'last_result': {}};
}

def recover(items: list[dict[str, any]], now: float) -> list[dict[str, any]] {
    values = [dict(d) for d in items];
    for d in values {
        if d['lease'] and d['lease_until'] <= now {
            if d['state'] == 'claimed' { d['state'] = 'queued'; }
            elif d['state'] == 'dispatching' { d['state'] = 'uncertain'; d['error'] = 'InterruptedDispatch'; }
            d['lease'] = ''; d['lease_until'] = 0.0;
        }
        if d['state'] == 'accepted' and (now - d['accepted_at']) >= RECEIPT_DEADLINE {
            d['state'] = 'uncertain'; d['error'] = 'ReceiptExpired'; d['lease'] = ''; d['lease_until'] = 0.0;
        }
        if d['state'] == 'accepted' and not d['lease'] and d['receipt_attempts'] >= MAX_RECEIPT_ATTEMPTS {
            d['state'] = 'uncertain'; d['error'] = 'ReceiptAttemptsExhausted';
        }
    }
    return values;
}

def status(items: list[dict[str, any]]) -> str {
    states = {d['state'] for d in items};
    if not states { return 'no_devices'; }
    if states & {'queued', 'claimed', 'dispatching'} { return 'sending'; }
    if 'accepted' in states { return 'accepted'; }
    if states == {'delivered'} { return 'delivered'; }
    if 'delivered' in states { return 'partial'; }
    if 'uncertain' in states { return 'uncertain'; }
    return 'failed';
}

def complete(d: dict[str, any], result: dict[str, any], now: float) -> dict[str, any] {
    value = dict(d); state = result.get('state'); polling = d['state'] == 'accepted';
    allowed = {'delivered', 'failed', 'pending', 'retry', 'retry_send', 'uncertain'} if polling else {'accepted', 'failed', 'retry', 'uncertain'};
    if state not in allowed { raise ValueError('Invalid notification result.'); }
    code = result.get('error', '');
    if not isinstance(code, str) or code not in (ERRORS | {'', 'ProviderRejected', 'ProviderUnavailable',
        'TransportUncertain', 'MissingCredential', 'InvalidResponse'}) { raise ValueError('Invalid notification error.'); }
    if state == 'accepted' {
        ticket = result.get('ticket');
        if not isinstance(ticket, str) or not ticket or len(ticket) > 200 { raise ValueError('Invalid push ticket.'); }
        value.update(state='accepted', ticket=ticket, accepted_at=now, due_at=now + RECEIPT_DELAY);
    } elif state == 'retry_send' {
        if d['attempts'] >= MAX_SEND_ATTEMPTS { value['state'] = 'failed'; code = 'SendAttemptsExhausted'; }
        else {
            value.update(state='queued', ticket='', accepted_at=0.0, receipt_attempts=0,
                due_at=now + 30 * (2 ** max(0, d['attempts'] - 1)));
        }
    } elif state in {'retry', 'pending'} {
        count = d['receipt_attempts'] if polling else d['attempts'];
        limit = MAX_RECEIPT_ATTEMPTS if polling else MAX_SEND_ATTEMPTS;
        if count >= limit {
            value['state'] = 'uncertain' if polling else 'failed';
            code = 'ReceiptAttemptsExhausted' if polling else 'SendAttemptsExhausted';
        } else {
            value['state'] = 'accepted' if polling else 'queued';
            value['due_at'] = now + (RECEIPT_DELAY if polling else 30 * (2 ** (count - 1)));
        }
    } else { value['state'] = state; }
    value.update(error=code, lease='', lease_until=0.0, last_lease=d['lease'], last_result=result);
    return value;
}
