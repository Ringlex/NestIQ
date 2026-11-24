#!/usr/bin/env python3
"""Atrapa urządzenia Tuya (włącznik 2-gangowy) zbudowana na tinytuya.

Do testów klienta Dart bez prawdziwego sprzętu, tak jak tool/fake_gateway dla
Mobilus. Strona urządzenia używa prymitywów referencyjnej biblioteki (ramki,
szyfrowanie), więc interoperacyjność sprawdzamy z kodem, którego nie napisaliśmy.

  .venv/bin/python tool/tuya/fake_device.py --version 3.4 --port 6668 \
      --id ebabcdef1234567890ab --key 0123456789abcdef
"""
import argparse, hmac, json, os, socketserver, struct, sys, time
from hashlib import sha256

from tinytuya.core import command_types as CT
from tinytuya.core import header as H
from tinytuya.core.crypto_helper import AESCipher
from tinytuya.core.message_helper import TuyaMessage, pack_message, parse_header, unpack_message

p = argparse.ArgumentParser()
p.add_argument("--version", default="3.3")
p.add_argument("--port", type=int, default=6668)
p.add_argument("--id", default="ebabcdef1234567890ab")
p.add_argument("--key", default="0123456789abcdef")
p.add_argument("--silent-control", action="store_true", help="nie potwierdzaj poleceń (tylko push)")
args = p.parse_args()

VERSION = args.version
REAL = args.key.encode()
STATE = {"1": False, "2": True}
HEADER = VERSION.encode() + b"\0" * 12


def j(obj):
    return json.dumps(obj).replace(" ", "").encode()


class Handler(socketserver.BaseRequestHandler):
    def setup(self):
        self.key = REAL
        self.seq = 100

    def send(self, cmd, plain, seqno, enc_plain=True):
        """Ramka urządzenie -> klient z kodem wyniku 0."""
        self.seq += 1
        if VERSION == "3.5":
            msg = TuyaMessage(self.seq, cmd, 0, plain, 0, True, H.PREFIX_6699_VALUE, os.urandom(12))
            self.request.sendall(pack_message(msg, hmac_key=self.key))
            return
        body = plain
        if plain and enc_plain:
            body = AESCipher(self.key).encrypt(plain, False)
        msg = TuyaMessage(self.seq, cmd, None, struct.pack(">I", 0) + body, 0, True, H.PREFIX_55AA_VALUE, None)
        self.request.sendall(pack_message(msg, hmac_key=self.key if VERSION == "3.4" else None))

    def recv_frame(self):
        buf = b""
        while len(buf) < 18:
            chunk = self.request.recv(18 - len(buf))
            if not chunk:
                return None
            buf += chunk
        header = parse_header(buf)
        while len(buf) < header.total_length:
            chunk = self.request.recv(header.total_length - len(buf))
            if not chunk:
                return None
            buf += chunk
        hmac_key = self.key if VERSION != "3.3" else None
        return unpack_message(buf, hmac_key=hmac_key, no_retcode=True)

    def decode(self, msg):
        payload = msg.payload
        if VERSION == "3.3":
            if payload.startswith(HEADER[:3]):
                payload = payload[15:]
            payload = AESCipher(self.key).decrypt(payload, False, decode_text=False)
        elif VERSION == "3.4":
            payload = AESCipher(self.key).decrypt(payload, False, decode_text=False)
        if payload.startswith(VERSION.encode()):
            payload = payload[15:]
        return json.loads(payload) if payload else {}

    def handle(self):
        local_nonce = None
        remote_nonce = os.urandom(16)
        while True:
            try:
                msg = self.recv_frame()
            except Exception as e:  # zła suma kontrolna itp.
                print("fake_device: błąd ramki:", e, file=sys.stderr, flush=True)
                return
            if msg is None:
                return
            if not msg.crc_good:
                print("fake_device: zła suma kontrolna/etykieta", file=sys.stderr, flush=True)
                return

            if msg.cmd == CT.SESS_KEY_NEG_START:
                payload = msg.payload
                if VERSION == "3.4":
                    payload = AESCipher(REAL).decrypt(payload, False, decode_text=False)
                local_nonce = payload[:16]
                proof = remote_nonce + hmac.new(REAL, local_nonce, sha256).digest()
                if VERSION == "3.4":
                    self.send(CT.SESS_KEY_NEG_RESP, proof, 0)
                else:
                    self.send(CT.SESS_KEY_NEG_RESP, proof, 0)
            elif msg.cmd == CT.SESS_KEY_NEG_FINISH:
                payload = msg.payload
                if VERSION == "3.4":
                    payload = AESCipher(REAL).decrypt(payload, False, decode_text=False)
                if payload[:32] != hmac.new(REAL, remote_nonce, sha256).digest():
                    print("fake_device: zły dowód klucza", file=sys.stderr, flush=True)
                    return
                mixed = bytes(a ^ b for a, b in zip(local_nonce, remote_nonce))
                if VERSION == "3.4":
                    self.key = AESCipher(REAL).encrypt(mixed, False, pad=False)
                else:
                    self.key = AESCipher(REAL).encrypt(mixed, use_base64=False, pad=False, iv=local_nonce[:12])[12:28]
                print("fake_device: sesja ustanowiona", file=sys.stderr, flush=True)
            elif msg.cmd in (CT.DP_QUERY, CT.DP_QUERY_NEW):
                self.send(msg.cmd, j({"devId": args.id, "dps": STATE}), msg.seqno)
            elif msg.cmd in (CT.CONTROL, CT.CONTROL_NEW):
                body = self.decode(msg)
                dps = body.get("dps") or body.get("data", {}).get("dps", {})
                STATE.update(dps)
                if not args.silent_control:
                    self.send(msg.cmd, b"", msg.seqno)
                # Zmiana stanu jest też rozgłaszana jak ze zwykłego przycisku.
                push = j({"dps": dps, "t": int(time.time())})
                if VERSION == "3.3":
                    self.send(CT.STATUS, HEADER + AESCipher(self.key).encrypt(push, False), msg.seqno, enc_plain=False)
                elif VERSION == "3.4":
                    self.send(CT.STATUS, HEADER + push, msg.seqno)
                else:
                    self.send(CT.STATUS, HEADER + push, msg.seqno)
            elif msg.cmd == CT.HEART_BEAT:
                self.send(CT.HEART_BEAT, b"", msg.seqno)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(("127.0.0.1", args.port), Handler) as srv:
    print("fake_device: nasłuchuje", args.port, "wersja", VERSION, file=sys.stderr, flush=True)
    srv.serve_forever()
