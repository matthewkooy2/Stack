"""Bounded latest-frame HTTP push. The public gateway never receives worker keys."""
import json
import socket
import time
import urllib.request


def serve(handler, host, ticket, duration=25):
    key = host.control.consume(ticket)
    host.control.watch(key, 1)
    try:
        handler.connection.settimeout(5)
        handler.send_response(200)
        handler.send_header('Content-Type', 'text/event-stream')
        handler.send_header('Cache-Control', 'no-store, no-transform')
        handler.send_header('X-Accel-Buffering', 'no')
        handler.send_header('Connection', 'close')
        handler.end_headers()
        deadline, sent, last, last_heartbeat = time.monotonic() + duration, 0, None, 0
        while time.monotonic() < deadline and sent < 4 * 1024 * 1024:
            state = host.control.state(key)
            frame = {} if state.get('revoked') or state['mode'] in ('stopping', 'stopped') else host.pool.frames.get(key)
            version = (frame.get('sequence'), state['generation'], state['mode'])
            now = time.monotonic()
            if version != last or now - last_heartbeat >= 2:
                payload = {'control': state, 'server_time': time.time(),
                    'observed_at': frame.get('observed_at', frame.get('captured_at', 0)),
                    'frame': frame if version != last else None}
                raw = ('data: ' + json.dumps(payload, separators=(',', ':')) + '\n\n').encode()
                if sent + len(raw) > 4 * 1024 * 1024:
                    break
                handler.wfile.write(raw)
                handler.wfile.flush()
                sent += len(raw)
                last, last_heartbeat = version, now
            if state.get('revoked') or state['mode'] == 'stopped':
                break
            # At most four updates per second; intermediate frames stay in one cache slot.
            time.sleep(.25)
    except (BrokenPipeError, ConnectionResetError, TimeoutError, socket.timeout):
        pass
    finally:
        host.control.watch(key, -1)
        handler.close_connection = True


def relay(handler, body, authorization, upstream):
    # Authorize every bounded connection through the existing authenticated account API.
    status, raw = upstream('/function/agent_browser_subscribe', body, authorization)
    result = json.loads(raw).get('data', {}).get('result', {})
    if status != 200 or result.get('error') or not result.get('ticket'):
        handler.send_error(403, 'This browser viewer is unavailable.')
        return
    request = urllib.request.Request(result['url'],
        data=json.dumps({'ticket': result['ticket']}).encode(),
        headers={'Content-Type': 'application/json'})
    # The URL is server configuration, never supplied by the app or a task.
    with urllib.request.urlopen(request, timeout=30) as response:
        handler.connection.settimeout(5)
        handler.send_response(200)
        handler.send_header('Content-Type', 'text/event-stream')
        handler.send_header('Cache-Control', 'no-store, no-transform')
        handler.send_header('X-Accel-Buffering', 'no')
        handler.send_header('Connection', 'close')
        handler.end_headers()
        sent = 0
        while sent < 4 * 1024 * 1024:
            line = response.readline(1024 * 1024)
            if not line:
                break
            handler.wfile.write(line)
            handler.wfile.flush()
            sent += len(line)
    handler.close_connection = True
