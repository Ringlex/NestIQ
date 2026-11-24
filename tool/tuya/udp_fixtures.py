#!/usr/bin/env python3
"""Rozgłoszenia UDP Tuya zbudowane przez tinytuya (test/tuya/udp_fixtures.json).

  .venv/bin/python tool/tuya/udp_fixtures.py > test/tuya/udp_fixtures.json
"""
import json, struct, sys

import tinytuya
from tinytuya.core import header as H
from tinytuya.core.crypto_helper import AESCipher
from tinytuya.core.message_helper import TuyaMessage, pack_message
from tinytuya.core.udp_helper import udpkey

ID = "ebabcdef1234567890ab"
IV = bytes(range(12))


def info(version):
    return json.dumps({"ip": "192.168.1.50", "gwId": ID, "active": 2, "ability": 0, "mode": 0,
                       "encrypt": True, "productKey": "keyxyz", "version": version}).replace(" ", "").encode()


# 6667: ramka 55AA, kod wyniku 0, ładunek szyfrowany kluczem UDP (urządzenia 3.3 / 3.4).
ecb = struct.pack(">I", 0) + AESCipher(udpkey).encrypt(info("3.3"), False)
frame_ecb = pack_message(TuyaMessage(1, 0x13, None, ecb, 0, True, H.PREFIX_55AA_VALUE, None))

# 6666: ładunek jawny (3.1).
plain = struct.pack(">I", 0) + info("3.1")
frame_plain = pack_message(TuyaMessage(1, 0, None, plain, 0, True, H.PREFIX_55AA_VALUE, None))

# 6667: ramka 6699 (3.5), z kodem wyniku i bez.
with_ret = pack_message(TuyaMessage(1, 0x13, 0, info("3.5"), 0, True, H.PREFIX_6699_VALUE, IV), hmac_key=udpkey)
without_ret = pack_message(TuyaMessage(1, 0x13, None, info("3.5"), 0, True, H.PREFIX_6699_VALUE, IV), hmac_key=udpkey)

# Zapytanie aplikacji na port 7000, po którym urządzenia 3.5 się ujawniają.
request = pack_message(
    TuyaMessage(0, tinytuya.REQ_DEVINFO, None, json.dumps({"from": "app", "ip": "192.168.1.10"}).replace(" ", "").encode(),
                0, True, H.PREFIX_6699_VALUE, IV), hmac_key=udpkey)

json.dump({"id": ID, "ip": "192.168.1.50", "ecb33": frame_ecb.hex(), "plain31": frame_plain.hex(),
           "gcm35": with_ret.hex(), "gcm35NoRetcode": without_ret.hex(), "request": request.hex(),
           "requestIp": "192.168.1.10"}, sys.stdout, indent=1)
