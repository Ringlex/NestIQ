#!/usr/bin/env python3
"""Podpisy żądań chmury Tuya liczone przez tinytuya (test/tuya/cloud_fixtures.json).

Zamiast sieci podstawiamy atrapę `requests`, która zapisuje, co biblioteka by
wysłała. Czas jest stały, więc podpisy są deterministyczne.

  .venv/bin/python tool/tuya/cloud_fixtures.py > test/tuya/cloud_fixtures.json
"""
import json, sys, time

import requests
import tinytuya

NOW_MS = 1700000000123
KEY, SECRET = "abcdefghijklmnopqrst", "0123456789abcdef0123456789abcdef"
time.time = lambda: NOW_MS / 1000.0
captured = []


class Resp:
    def __init__(self, body):
        self.content = json.dumps(body).encode()
        self.text = json.dumps(body)
        self.status_code = 200


def fake(method):
    def call(url, headers=None, data=None, **kw):
        m = method or kw.get("method")
        captured.append({"method": m, "url": url, "headers": dict(headers or {}), "body": data or ""})
        if "token" in url:
            return Resp({"success": True, "result": {"access_token": "TOKEN123", "expire_time": 7200}, "t": NOW_MS})
        return Resp({"success": True, "result": {}})
    return call


requests.get = fake("GET")
requests.request = lambda action, url, headers=None, data=None, **kw: fake(action)(url, headers=headers, data=data)

c = tinytuya.Cloud(apiRegion="eu", apiKey=KEY, apiSecret=SECRET, apiDeviceID="x")
c.cloudrequest("/v1.0/iot-01/associated-users/devices", query={"size": "50", "last_row_key": "abc"})
c.cloudrequest("/v1.0/iot-03/devices/ebabcdef1234567890ab/commands", action="POST",
               post={"commands": [{"code": "switch_1", "value": True}]})
c.cloudrequest("/v1.0/iot-03/devices/ebabcdef1234567890ab/status")

out = {"clientId": KEY, "secret": SECRET, "now": NOW_MS, "requests": []}
for r in captured:
    path = "/" + r["url"].split("//", 1)[1].split("/", 1)[1]
    out["requests"].append({
        "method": r["method"], "path": path, "body": r["body"],
        "sign": r["headers"]["sign"], "t": r["headers"]["t"],
        "token": r["headers"].get("access_token"),
        "signedHeaders": r["headers"].get("Signature-Headers", ""),
    })
json.dump(out, sys.stdout, indent=1)
