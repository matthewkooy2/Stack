"""Operator-selected local inference; bounded transport and strict structured proposals."""
import ipaddress;
import json;
import os;
import time;
import socket;
import from threading { Event, Timer }
import from urllib.parse { urlsplit }
import from http.client { HTTPConnection, HTTPSConnection, HTTPException, HTTPResponse }

with entry {
    RESPONSE_LIMIT = 262144;
    OUTPUT_LIMIT = 65536;
}

def origin(provider: str, value: str = '') -> str {
    default_url = 'http://127.0.0.1:11434'
        if provider == 'ollama'
        else 'http://127.0.0.1:1234';
    try {
        parts = urlsplit(value or default_url);
        host = parts.hostname or '';
        if host == 'localhost' {
            host = '127.0.0.1';
        }
        address = ipaddress.ip_address(host);
        allowed = address.is_loopback
            or `any(
                address in ipaddress.ip_network(n)
                for n in ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', 'fc00::/7']
            );
        if provider not in ['ollama', 'lmstudio']
            or parts.scheme not in ['http', 'https']
            or not allowed
            or parts.username is not None
            or parts.password is not None
            or parts.path not in ['', '/']
            or parts.query
            or parts.fragment
            or not parts.port {
            raise ValueError('Invalid local inference origin.');
        }
        rendered = '[' + host + ']' if ':' in host else host;
        return parts.scheme + '://' + rendered + ':' + str(parts.port);
    } except ValueError {
        raise ValueError(
            'Set a local model HTTP(S) origin with an explicit port on loopback or a private IP, without credentials, path, query or fragment.'
        ) from None;
    }
}


def unique_object(pairs: list[tuple[str, any]]) -> dict[str, any] {
    value: dict[str, any] = {};
    for (key, item) in pairs {
        if key in value {
            raise ValueError('Duplicate local model JSON field.');
        }
        value[key] = item;
    }
    return value;
}

def invalid_number(value: str) -> any {
    raise ValueError('Invalid local model JSON number.');
}

def decode(text: str) -> any {
    try {
        return json.loads(
            text, object_pairs_hook=unique_object, parse_constant=invalid_number
        );
    } except (ValueError, RecursionError) {
        raise ValueError('The local model returned invalid JSON.') from None;
    }
}

# These are the schema keywords used by Stack's structured workflows. Fail closed
# if a future schema adds a constraint this validator does not implement.
def validate(value: any, schema: dict[str, any], depth: int = 0) {
    if depth > 32
        or not (
            `set(schema)
            <= {
                'type',
                'properties',
                'required',
                'additionalProperties',
                'items',
                'enum',
                'minimum',
                'maximum',
                'maxItems'
            }
        ) {
        raise ValueError('Unsupported local model schema.');
    }
    kind = schema['type'];
    if kind == 'object' {
        if not isinstance(value, `dict) {
            raise ValueError('Local model output does not match the schema.');
        }
        props = schema['properties'];
        if not (`set(schema['required']) <= `set(value))
            or (
                schema.get('additionalProperties') is False
                and not (`set(value) <= `set(props))
            ) {
            raise ValueError('Local model output has missing or unexpected fields.');
        }
        for (key, item) in value.items() {
            validate(item, props[key], depth + 1);
        }
    } elif kind == 'array' {
        if not isinstance(value, `list) or len(value) > schema.get('maxItems', 1000) {
            raise ValueError('Local model output does not match the array schema.');
        }
        for item in value {
            validate(item, schema['items'], depth + 1);
        }
    } elif kind == 'string' {
        if not isinstance(value, str) {
            raise ValueError('Local model output does not match the text schema.');
        }
    } elif kind == 'integer' {
        if `type(value) is not int
            or value < schema.get('minimum', -2147483648)
            or value > schema.get('maximum', 2147483647) {
            raise ValueError('Local model output does not match the score schema.');
        }
    } else {
        raise ValueError('Unsupported local model schema type.');
    }
    if 'enum' in schema and value not in schema['enum'] {
        raise ValueError('Local model output has an invalid choice.');
    }
}

def complete(
    step: str,
    system: str,
    prompt: str,
    schema: dict[str, any],
    c: dict[str, any],
    received: any
) -> dict[str, any] {
    provider = c['provider'];
    base = origin(provider, c.get('local_model_url', ''));
    if not c['model'].strip() {
        raise ValueError('Choose an installed local model.');
    }
    context_tokens = c.get('local_model_context_tokens', 8192);
    output_tokens = c['max_output_tokens'];
    # UTF-8 bytes conservatively bound input tokens. Do not silently truncate
    # sources to fit a local context window. Reserve space for chat framing.
    input_bytes = len(system.encode())
        + len(prompt.encode())
        + len(json.dumps(schema).encode());
    if input_bytes + output_tokens + 512 > context_tokens {
        raise ValueError(
            'This task exceeds the local model context limit. Increase the configured context and load the model with that context before retrying.'
        );
    }
    messages = [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': prompt}
    ];
    if provider == 'ollama' {
        path = '/api/chat';
        payload = {
            'model': c['model'],
            'messages': messages,
            'format': schema,
            'stream': False,
            'think': False,
            'options': {
                'temperature': 0,
                'num_predict': output_tokens,
                'num_ctx': context_tokens
            }
        };
    } else {
        path = '/v1/chat/completions';
        payload = {
            'model': c['model'],
            'messages': messages,
            'temperature': 0,
            'stream': False,
            'max_tokens': output_tokens,
            'response_format': {
                'type': 'json_schema',
                'json_schema': {
                    'name': 'stack_' + step,
                    'strict': True,
                    'schema': schema
                }
            }
        };
    }
    headers = {'Content-Type': 'application/json', 'Accept': 'application/json'};
    token = os.environ.get('STACK_LOCAL_MODEL_API_KEY', '');
    if token {
        headers['Authorization'] = 'Bearer ' + token;
    }
    seconds = min(90, max(5, c.get('local_model_timeout', 90)));
    deadline = time.monotonic() + seconds;
    parts = urlsplit(base);
    connection = HTTPSConnection(parts.hostname, parts.port, timeout=seconds)
        if parts.scheme == 'https'
        else HTTPConnection(parts.hostname, parts.port, timeout=seconds);
    expired = Event();
    watched: list[socket.socket | None] = [None];
    def abort() {
        expired.set();
        transport = watched[0] or connection.sock;
        if transport is not None {
            try {
                transport.shutdown(socket.SHUT_RDWR);
            } except OSError {
                ;
            }
        }
        connection.close();
    }
    timer = Timer(seconds, abort);
    timer.daemon = True;
    chunks = [];
    size = 0;
    timer.start();
    try {
        # Direct HTTP connections never consult proxies or follow redirects.
        # The watchdog bounds connect, request writes, and response headers too.
        connection.request(
            'POST', path, body=json.dumps(payload).encode(), headers=headers
        );
        watched[0] = connection.sock;
        with connection.getresponse() as incoming {
            response = incoming as HTTPResponse;
            if expired.is_set() or time.monotonic() > deadline { raise TimeoutError(); }
            if response.status != 200 {
                raise ValueError(
                    'The local model service rejected the request. Check the selected model and local service authorization.'
                );
            }
            if response.headers.get_content_type() != 'application/json' {
                raise ValueError(
                    'The local model service returned an unsupported response format.'
                );
            }
            while True {
                if response.isclosed() {
                    if response.length not in [None, 0] {
                        raise ValueError('The local model response was truncated.');
                    }
                    break;
                }
                remaining = deadline - time.monotonic();
                if remaining <= 0 or expired.is_set() {
                    raise TimeoutError();
                }
                transport = watched[0];
                if transport is None {
                    raise ValueError(
                        'The local model connection closed before completion.'
                    );
                }
                transport.settimeout(remaining);
                chunk = response.read1(min(16384, RESPONSE_LIMIT + 1 - size));
                if not chunk {
                    if response.length not in [None, 0] {
                        raise ValueError('The local model response was truncated.');
                    }
                    break;
                }
                size += len(chunk);
                if size > RESPONSE_LIMIT {
                    raise ValueError(
                        'The local model response exceeded the output limit.'
                    );
                }
                chunks.append(chunk);
            }
        }
        if expired.is_set() or time.monotonic() > deadline {
            raise TimeoutError();
        }
    } except TimeoutError {
        raise ValueError(
            'Local inference timed out. Check model capacity before retrying.'
        ) from None;
    } except (OSError, HTTPException) {
        if expired.is_set() {
            raise ValueError(
                'Local inference timed out. Check model capacity before retrying.'
            ) from None;
        }
        raise ValueError(
            'The local model service or selected model is unavailable. Start the service and check the model before retrying.'
        ) from None;
    } finally {
        timer.cancel();
        connection.close();
    }
    body = b''.join(chunks);
    received(body.decode('utf-8', errors='replace'), 'provider_json');
    try {
        raw = body.decode('utf-8');
    } except UnicodeError {
        raise ValueError('The local model returned invalid UTF-8.') from None;
    }
    result = decode(raw);
    if not isinstance(result, `dict) or result.get('error') {
        raise ValueError(
            'The local model service rejected the request. Check the selected model.'
        );
    }
    if provider == 'ollama' {
        if result.get('done') is not True or result.get('done_reason') != 'stop' {
            raise ValueError('The local model did not complete this step.');
        }
        message = result.get('message');
    } else {
        choices = result.get('choices');
        if not isinstance(choices, `list)
            or len(choices) != 1
            or not isinstance(choices[0], `dict)
            or choices[0].get('finish_reason') != 'stop' {
            raise ValueError('The local model did not complete this step.');
        }
        message = choices[0].get('message');
    }
    if not isinstance(message, `dict)
        or message.get('tool_calls')
        or message.get('refusal') {
        raise ValueError('The local model did not return a structured proposal.');
    }
    text = message.get('content');
    model = result.get('model');
    if not isinstance(text, str)
        or not text.strip()
        or len(text.encode()) > OUTPUT_LIMIT
        or not isinstance(model, str)
        or not model.strip() {
        raise ValueError(
            'The local model returned an empty or oversized proposal, or missing model metadata.'
        );
    }
    data = decode(text);
    validate(data, schema);
    return {'text': text, 'model': model, 'id': result.get('id', ''), 'usage': {}};
}
