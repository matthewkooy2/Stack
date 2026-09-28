"""Encryption and outbound HTTP for fixed provider origins."""
import base64;
import json;
import os;
import urllib.error;
import urllib.request;
def seal(value: any) -> str {
    import from cryptography.fernet { Fernet }
    key = os.environ.get('STACK_CONNECTION_KEY', '');
    if not key {
        raise ValueError(
            'Connections are disabled until the operator configures encryption.'
        );
    }
    return Fernet(key.encode()).encrypt(json.dumps(value).encode()).decode();
}
def unseal(value: str) -> dict[(str, any)] {
    import from cryptography.fernet { Fernet }
    try {
        return json.loads(
            Fernet(os.environ['STACK_CONNECTION_KEY'].encode()).decrypt(value.encode())
        );
    } except Exception {
        raise ValueError(
            'Connection could not be unlocked. Reconnect your account.'
        ) from None;
    }
}
class NoRedirect(urllib.request.HTTPRedirectHandler) {
    def redirect_request(
        self: NoRedirect,
        req: any,
        fp: any,
        code: any,
        msg: any,
        headers: any,
        newurl: any
    ) {
        raise ValueError('Unexpected provider redirect.');
    }
}
def http(
    url: str,
    body: any = None,
    headers: dict[str, str] | None = None,
    method: str | None = None,
    timeout: float = 45
) -> dict[str, any] {
    import from urllib.parse { urlsplit }
    if (
        (urlsplit(url).scheme != 'https')
        or (
            urlsplit(url).hostname
            not in {
                'api.openai.com',
                'oauth2.googleapis.com',
                'www.googleapis.com',
                'gmail.googleapis.com',
                'accounts.google.com',
                'fcm.googleapis.com',
                'exp.host',
                'pubsub.googleapis.com'
            }
        )
    ) {
        raise ValueError('Provider destination is not allowed.');
    }
    data = body
        if isinstance(body, `bytes)
        else json.dumps(body).encode() if (body is not None) else None;
    req = urllib.request.Request(
        url, data=data, headers=(headers or {}), method=method
    );
    try {
        with urllib.request.build_opener(NoRedirect).open(
            req, timeout=timeout
        ) as response {
            raw = response.read(((8 * 1024 * 1024) + 1));
            if (len(raw) > (8 * 1024 * 1024)) {
                raise ValueError('Provider response exceeds the size limit.');
            }
            return json.loads(raw) if raw else {};
        }
    } except urllib.error.HTTPError as exc {
        # Provider bodies and URLs may contain credentials or private content.
        if (exc.code in (401, 403)) {
            raise ValueError(
                'Provider authorization failed. Reconnect or check configuration.'
            ) from None;
        }
        raise ValueError(
            ('Provider request failed (HTTP ' + str(exc.code) + ').')
        ) from None;
    }
}
def b64url(value: bytes) -> str {
    return base64.urlsafe_b64encode(value).rstrip(b'=').decode();
}
