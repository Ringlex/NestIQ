import sys, struct, time
# Atrapa bramki Mobilus Cosmo GTW do testów bez sprzętu.
# Użycie: python fake_gateway.py <ścieżka do repo mobilus-client>
# Login: admin / hasło: secret
sys.path.insert(0, sys.argv[1])
import paho.mqtt.client as mqtt
from mobilus_client.utils.encryption import create_key, create_iv, encrypt_body, decrypt_body
from mobilus_client.proto import (LoginRequest, LoginResponse, DevicesListResponse,
    CurrentStateResponse, CallEventsRequest)
USER_KEY = create_key("secret"); PRIV = bytes(range(32)); PUB = bytes(range(32, 64))
def frame(cat, key, msg, cid=b"\x00"*6):
    ts = int(time.time())
    return struct.pack(">IBI", 13, cat, ts) + cid + bytes([4, 0]) + encrypt_body(key, create_iv(ts), msg.SerializeToString())
def on_message(c, _u, m):
    p = m.payload; cat = p[4]; ts = struct.unpack(">I", p[5:9])[0]; cid = p[9:15]; body = p[17:]
    topic = cid.hex().upper()
    print("gateway got category", cat, "from", topic, flush=True)
    if cat == 1:
        req = LoginRequest(); req.ParseFromString(body)
        r = LoginResponse()
        if req.login == "admin" and req.password == USER_KEY:
            r.login_status = 0; r.private_key = PRIV; r.public_key = PUB; r.serial_number = "FAKE-GTW"; r.user_id = 1
        else:
            r.login_status = 1
        c.publish(topic, frame(2, USER_KEY, r))
    elif cat == 3:
        r = DevicesListResponse()
        for i, (n, t) in enumerate([("Salon", 2), ("Sypialnia", 1), ("Garaż", 4)]):
            d = r.devices.add(); d.id = i; d.name = n; d.type = t
        c.publish(topic, frame(4, PRIV, r))
    elif cat == 26:
        r = CurrentStateResponse(); e = r.events.add(); e.device_id = 1; e.event_number = 8; e.value = "40%"
        c.publish(topic, frame(27, PRIV, r))
    elif cat == 13:
        req = CallEventsRequest(); req.ParseFromString(decrypt_body(PRIV, create_iv(ts), body))
        ev = req.events[0]; print("command", ev.device_id, ev.value, flush=True)
        n = CallEventsRequest(); e = n.events.add(); e.device_id = ev.device_id; e.event_number = 8; e.value = ev.value
        c.publish("clients", frame(13, PUB, n))
c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id="gateway", transport="websockets")
c.on_message = on_message
c.on_connect = lambda c, *a: (c.subscribe("module"), print("gateway ready", flush=True))
c.connect("127.0.0.1", 8884); c.loop_forever()
