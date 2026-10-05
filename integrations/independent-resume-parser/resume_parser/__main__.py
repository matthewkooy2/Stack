import argparse
import json
import sys
from . import Limits, ParseError, parse_pdf
from .report import render_html

parser = argparse.ArgumentParser(description='Offline PDF resume parser; JSON to stdout')
parser.add_argument('pdf')
parser.add_argument('--node', help='Trusted Node >=22.13 executable path')
parser.add_argument('--format', choices=('json', 'html'), default='json', help='Full editable JSON or read-only table report')
args = parser.parse_args()
# The review document is UTF-8 JSON on every OS, including redirected output
# under legacy Windows console encodings. Keep byte accounting identical too.
sys.stdout.reconfigure(encoding='utf-8', newline='\n')
try:
    result = parse_pdf(args.pdf, node=args.node)
    output = (render_html(result) if args.format == 'html' else
              json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    if len(output.encode('utf-8')) > Limits().output_bytes:
        raise ParseError('OUTPUT_LIMIT')
    sys.stdout.write(output)
except ParseError as error:
    print(json.dumps({'error': error.code}), file=sys.stderr)
    sys.exit(2)
