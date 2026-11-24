#!/usr/bin/env python3
"""Generuje test/tuya/fixtures.json referencyjną biblioteką tinytuya.

Czas i losowość są stałe, więc ramki są deterministyczne i klient Dart musi
zbudować dokładnie te same bajty. Tinytuya gra też stronę urządzenia (odpowiedzi
negocjacji, status), więc dekodowanie po stronie Dart jest sprawdzane na ramkach
nie napisanych przez nas.

  python3 -m venv .venv && .venv/bin/pip install tinytuya
  .venv/bin/python tool/tuya/fixtures.py > test/tuya/fixtures.json
"""
import hmac, importlib, json, struct, sys, time
from hashlib import sha256

import tinytuya
from tinytuya.core import crypto_helper
from tinytuya.core import command_types as CT
from tinytuya.core import header as H
from tinytuya.core.crypto_helper import AESCipher
from tinytuya.core.message_helper import TuyaMessage, pack_message, unpack_message

X = importlib.import_module('tinytuya.core.XenonDevice')
DEV_ID = "ebabcdef1234567890ab"
KEY = "0123456789abcdef"
NOW = 1700000000

time.time = lambda: float(NOW)
det = lambda n: bytes(range(n))
X.os.urandom = det
crypto_helper.os.urandom = det

REMOTE_NONCE = bytes(range(100, 116))
DEVICE_IV = bytes(range(50, 62))
hx = lambda b: b.hex()


def device_frame(version, cmd, plain, enc_key, seqno, hmac_key=None):
    """Ramka urządzenie -> klient (z kodem wyniku 0), budowana prymitywami tinytuya."""
    if version == "3.5":
        msg = TuyaMessage(seqno, cmd, 0, plain, 0, True, H.PREFIX_6699_VALUE, DEVICE_IV)
        return pack_message(msg, hmac_key=enc_key)
    body = struct.pack(">I", 0) + plain
    msg = TuyaMessage(seqno, cmd, None, body, 0, True, H.PREFIX_55AA_VALUE, None)
    return pack_message(msg, hmac_key=hmac_key)


def build(version):
    v = float(version)
    d = tinytuya.Device(DEV_ID, "127.0.0.1", KEY, version=v)
    real = KEY.encode()
    out = {"version": version, "deviceId": DEV_ID, "key": KEY, "now": NOW, "frames": {}}
    f = out["frames"]

    if v >= 3.4:
        f["negStart"] = hx(d._encode_message(d._negotiate_session_key_generate_step_1()))
        local_nonce = d.local_nonce
        proof = REMOTE_NONCE + hmac.new(real, local_nonce, sha256).digest()
        if version == "3.4":
            wire = device_frame(version, CT.SESS_KEY_NEG_RESP, AESCipher(real).encrypt(proof, False), real, 1, hmac_key=real)
        else:
            wire = device_frame(version, CT.SESS_KEY_NEG_RESP, proof, real, 1)
        f["negResp"] = hx(wire)
        resp = unpack_message(wire, hmac_key=real, no_retcode=False)
        step3 = d._negotiate_session_key_generate_step_3(resp)
        f["negFinish"] = hx(d._encode_message(step3))
        d._negotiate_session_key_generate_finalize()
        session = d.local_key
    else:
        session = real
    out["sessionKey"] = hx(session)

    f["control"] = hx(d._encode_message(d.generate_payload(CT.CONTROL, {"1": True, "2": False})))
    f["query"] = hx(d._encode_message(d.generate_payload(CT.DP_QUERY)))
    f["heartbeat"] = hx(d._encode_message(d.generate_payload(CT.HEART_BEAT)))

    # Odpowiedzi urządzenia: status z nagłówkiem wersji i odpowiedź na zapytanie bez niego.
    header = b"3.3" + b"\0" * 12 if version == "3.3" else version.encode() + b"\0" * 12
    push = json.dumps({"dps": {"1": True, "2": False}, "t": NOW}).replace(" ", "").encode()
    answer = json.dumps({"devId": DEV_ID, "dps": {"1": False, "2": True, "9": 25}}).replace(" ", "").encode()
    sk = AESCipher(session)
    if version == "3.3":
        f["status"] = hx(device_frame(version, CT.STATUS, header + sk.encrypt(push, False), session, 7))
        f["queryResponse"] = hx(device_frame(version, CT.DP_QUERY, sk.encrypt(answer, False), session, 8))
        f["controlAck"] = hx(device_frame(version, CT.CONTROL, b"", session, 9))
    elif version == "3.4":
        f["status"] = hx(device_frame(version, CT.STATUS, sk.encrypt(header + push, False), session, 7, hmac_key=session))
        f["queryResponse"] = hx(device_frame(version, CT.DP_QUERY_NEW, sk.encrypt(answer, False), session, 8, hmac_key=session))
        f["controlAck"] = hx(device_frame(version, CT.CONTROL_NEW, b"", session, 9, hmac_key=session))
    else:
        f["status"] = hx(device_frame(version, CT.STATUS, header + push, session, 7))
        f["queryResponse"] = hx(device_frame(version, CT.DP_QUERY_NEW, answer, session, 8))
        f["controlAck"] = hx(device_frame(version, CT.CONTROL_NEW, b"", session, 9))
    out["statusDps"] = {"1": True, "2": False}
    out["queryDps"] = {"1": False, "2": True, "9": 25}
    return out


json.dump([build(v) for v in ("3.3", "3.4", "3.5")], sys.stdout, indent=1)
