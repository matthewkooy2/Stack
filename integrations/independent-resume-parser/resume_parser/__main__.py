import argparse
import json
import sys
from . import ParseError, parse_pdf

parser = argparse.ArgumentParser(description='Offline PDF resume parser; JSON to stdout')
parser.add_argument('pdf')
parser.add_argument('--node', help='Trusted Node >=22.13 executable path')
args = parser.parse_args()
try:
    print(json.dumps(parse_pdf(args.pdf, node=args.node), ensure_ascii=False, indent=2))
except ParseError as error:
    print(json.dumps({'error': error.code}), file=sys.stderr)
    sys.exit(2)
