#!/usr/bin/env bash
set -euo pipefail

URL="https://www.wetest.vip/page/cloudflare/address_v6.html"
ZONE_NAME="xxx"
API_TOKEN="xxx"

if [ -z "$API_TOKEN" ]; then
    echo "ERROR: CF_API_TOKEN environment variable is not set." >&2
    echo "Please set it before running: export CF_API_TOKEN=your_token" >&2
    exit 1
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

curl -fsSL "$BESTV6_URL" > "$TMPFILE"

python3 - "$TMPFILE" "$ZONE_NAME" "$API_TOKEN" <<'PY'
import json
import os
import re
import sys
import urllib.parse
import urllib.request

if len(sys.argv) != 4:
    print("Usage: script.py <html_file> <zone_name> <api_token>", file=sys.stderr)
    sys.exit(1)

html_file, zone_name, api_token = sys.argv[1], sys.argv[2], sys.argv[3]

with open(html_file, encoding='utf-8') as f:
    html = f.read()

pattern = re.compile(
    r'<tr>.*?<td[^>]*data-label="线路名称">([^<]+)</td>.*?'
    r'<td[^>]*data-label="优选地址">([^<]+)</td>.*?'
    r'<td[^>]*data-label="往返延迟">\s*([0-9]+)\s*毫秒</td>',
    re.S,
)

best = {'移动': (10**9, ''), '联通': (10**9, ''), '电信': (10**9, '')}
for line, addr, latency in pattern.findall(html):
    latency = int(latency)
    if line in best and latency < best[line][0]:
        best[line] = (latency, addr)

mapping = {'移动': 'yidong', '联通': 'liantong', '电信': 'dianxin'}
headers = {
    'Authorization': f'Bearer {api_token}',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
}


def cf_request(method, url, data=None, params=None):
    if params:
        url = url + '?' + urllib.parse.urlencode(params)
    body = None
    if data is not None:
        body = json.dumps(data).encode('utf-8')
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req) as resp:
        resp_body = resp.read().decode('utf-8')
    return json.loads(resp_body)


def get_zone_id():
    resp = cf_request('GET', 'https://api.cloudflare.com/client/v4/zones', params={'name': zone_name, 'status': 'active'})
    if not resp.get('success') or not resp.get('result'):
        raise SystemExit(f'Cloudflare zone lookup failed: {resp}')
    if len(resp['result']) == 0:
        raise SystemExit(f'Zone {zone_name} not found for this token.')
    return resp['result'][0]['id']


def get_dns_record(zone_id, name):
    resp = cf_request('GET', f'https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records', params={'type': 'AAAA', 'name': name})
    if not resp.get('success'):
        raise SystemExit(f'Cloudflare DNS record lookup failed for {name}: {resp}')
    return resp['result'][0] if resp.get('result') else None


def update_record(zone_id, record_id, name, content):
    data = {'type': 'AAAA', 'name': name, 'content': content, 'ttl': 1, 'proxied': False}
    return cf_request('PUT', f'https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}', data=data)


def create_record(zone_id, name, content):
    data = {'type': 'AAAA', 'name': name, 'content': content, 'ttl': 1, 'proxied': False}
    return cf_request('POST', f'https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records', data=data)

zone_id = get_zone_id()

for carrier in ['移动', '联通', '电信']:
    latency, addr = best[carrier]
    if not addr:
        print(f'{carrier}: no address found, skipped')
        continue
    record_name = f"{mapping[carrier]}.{zone_name}"
    existing = get_dns_record(zone_id, record_name)
    if existing:
        if existing.get('content') == addr:
            print(f'{carrier}: {record_name} already set to {addr}')
        else:
            update_record(zone_id, existing['id'], record_name, addr)
            print(f'{carrier}: {record_name} updated to {addr}')
    else:
        create_record(zone_id, record_name, addr)
        print(f'{carrier}: {record_name} created with {addr}')
PY