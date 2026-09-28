"""Push contains no resume, contact, employer, or email content."""
import os
from agents.security import http


def deliver(device, notice):
    secret = os.environ.get('EXPO_ACCESS_TOKEN', '')
    if not secret:
        raise ValueError('Remote notifications require the deployment push credential.')
    result = http('https://exp.host/--/api/v2/push/send', {
        'to': device, 'title': 'Stack', 'body': 'An agent task needs your attention.',
        'data': {'user_id': notice['owner'], 'target_type': 'agent', 'target_id': notice['run_id']},
        'sound': 'default',
    }, {'Authorization': 'Bearer ' + secret, 'Content-Type': 'application/json'})
    receipt = result.get('data', {})
    if receipt.get('status') != 'ok':
        raise ValueError('Push delivery was not accepted.')
    return receipt['id']
