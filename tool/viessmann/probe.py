#!/usr/bin/env python3
"""Sprawdza, co API Viessmanna (ViCare) zwraca dla Twojego pieca.

Loguje Cię w przeglądarce (OAuth2 + PKCE), więc hasło do ViCare nie trafia do
skryptu. Wypisuje urządzenia i nazwy funkcji; numery seryjne i identyfikatory są
domyślnie zamaskowane, żeby dało się bezpiecznie wkleić wynik.

Wymaga Pythona 3.8+, bez dodatkowych pakietów.

  python3 tool/viessmann/probe.py --client-id TWOJ_CLIENT_ID

W portalu deweloperskim (My Dashboard -> Twój klient) musi być dodany adres
przekierowania:  http://localhost:4200/
"""
import argparse, base64, hashlib, http.server, json, secrets, sys, threading, urllib.error, urllib.parse, urllib.request, webbrowser

IAM = "https://iam.viessmann-climatesolutions.com/idp/v3"
API = "https://api.viessmann-climatesolutions.com/iot/v2"
REDIRECT = "http://localhost:4200/"


def pkce():
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    return verifier, challenge


def authorize_url(client_id, challenge, state):
    query = urllib.parse.urlencode({
        "client_id": client_id,
        "redirect_uri": REDIRECT,
        "scope": "IoT User",
        "response_type": "code",
        "code_challenge_method": "S256",
        "code_challenge": challenge,
        "state": state,
    })
    return f"{IAM}/authorize?{query}"


def wait_for_code(state, timeout=180):
    """Lokalny serwer na porcie 4200 odbiera przekierowanie po zalogowaniu."""
    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if "code" in query or "error" in query:
                result.update({k: v[0] for k, v in query.items()})
                body = "Zalogowano. Możesz zamknąć tę kartę i wrócić do terminala."
                self.send_response(200)
            else:
                body = "Czekam na logowanie…"
                self.send_response(404)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode())

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 4200), Handler)
    server.timeout = 1
    thread_done = threading.Event()

    def serve():
        waited = 0
        while not result and waited < timeout:
            server.handle_request()
            waited += 1
        thread_done.set()

    threading.Thread(target=serve, daemon=True).start()
    return result, thread_done, server


def post_form(url, data):
    request = urllib.request.Request(url, urllib.parse.urlencode(data).encode(),
                                     {"Content-Type": "application/x-www-form-urlencoded"})
    return json.load(urllib.request.urlopen(request, timeout=30))


def get_json(url, token):
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response), response.headers


SENSITIVE = ("serial", "etn", "houseLocation", "wifi", "ssid", "mac")


def sensitive(feature_name):
    return any(word.lower() in feature_name.lower() for word in SENSITIVE)


def describe(value):
    """Skrót wartości właściwości: liczba z jednostką, tekst, lista; zagnieżdżone obiekty rozwijane płytko."""
    if isinstance(value, dict) and "value" in value:
        unit = value.get("unit", "")
        return f"{value['value']} {unit}".strip()
    if isinstance(value, dict):
        return "{" + ", ".join(f"{k}={describe(v)}" for k, v in list(value.items())[:6]) + "}"
    if isinstance(value, list):
        return "[" + ", ".join(describe(v) for v in value[:4]) + ("…" if len(value) > 4 else "") + "]"
    return str(value)


def command_info(commands):
    out = []
    for name, cmd in commands.items():
        params = cmd.get("params", {})
        ranges = []
        for pname, p in params.items():
            c = p.get("constraints", {})
            bits = [p.get("type", "")]
            for key in ("min", "max", "stepping", "enum", "regEx"):
                if key in c:
                    bits.append(f"{key}={c[key]}")
            ranges.append(f"{pname}({' '.join(str(b) for b in bits if b != '')})")
        out.append(f"{name}[{'; '.join(ranges)}]" if ranges else name)
    return out


def mask(value, show):
    value = str(value)
    return value if show else (value[:2] + "…" + value[-2:] if len(value) > 6 else "…")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--show-ids", action="store_true", help="nie maskuj numerów seryjnych i identyfikatorów")
    parser.add_argument("--events", action="store_true", help="sprawdź też historię zdarzeń (opisy usterek)")
    parser.add_argument("--save", metavar="PLIK", help="zapisz pełne odpowiedzi API do pliku JSON (u siebie)")
    args = parser.parse_args()

    verifier, challenge = pkce()
    state = secrets.token_urlsafe(16)
    result, done, server = wait_for_code(state)

    url = authorize_url(args.client_id, challenge, state)
    print("Otwieram przeglądarkę do zalogowania (konto ViCare). Jeśli się nie otworzy, wejdź na:\n" + url + "\n")
    webbrowser.open(url)
    done.wait(190)
    server.server_close()

    if "error" in result:
        sys.exit(f"Logowanie odrzucone: {result.get('error')} {result.get('error_description', '')}")
    if "code" not in result:
        sys.exit("Nie doczekałem się logowania (3 min). Sprawdź, czy adres przekierowania http://localhost:4200/ jest dodany w portalu.")
    if result.get("state") != state:
        sys.exit("Niezgodny parametr state: przerywam.")

    try:
        token = post_form(f"{IAM}/token", {
            "grant_type": "authorization_code",
            "client_id": args.client_id,
            "redirect_uri": REDIRECT,
            "code": result["code"],
            "code_verifier": verifier,
        })
    except urllib.error.HTTPError as e:
        sys.exit(f"Wymiana kodu na token nie powiodła się: HTTP {e.code} {e.read().decode()[:300]}")
    access = token["access_token"]
    print(f"Zalogowano. Token ważny {token.get('expires_in', '?')} s, zakres: {token.get('scope', '?')}\n")

    saved = {}
    installations, headers = get_json(f"{API}/equipment/installations?includeGateways=true", access)
    saved["installations"] = installations
    for inst in installations.get("data", []):
        label = inst.get("description", "") if args.show_ids else "…"
        print(f"Instalacja {mask(inst.get('id'), args.show_ids)} ({label})")
        for gw in inst.get("gateways", []):
            serial = gw.get("serial")
            print(f"  Brama {mask(serial, args.show_ids)}  typ: {gw.get('gatewayType')}  wersja: {gw.get('version')}  status: {gw.get('aggregatedStatus')}")
            for dev in gw.get("devices", []):
                dev_id = dev.get("id")
                print(f"    Urządzenie {dev_id}: {dev.get('modelId')} ({dev.get('deviceType')}), status: {dev.get('status')}")
                feat_url = f"{API}/features/installations/{inst['id']}/gateways/{serial}/devices/{dev_id}/features"
                try:
                    feats, _ = get_json(feat_url, access)
                except urllib.error.HTTPError as e:
                    print(f"      (nie udało się pobrać funkcji: HTTP {e.code})")
                    continue
                saved[f"features_{dev_id}"] = feats
                data = feats.get("data", [])
                print(f"      Funkcje: {len(data)}")
                for f in data:
                    name = f.get("feature", "")
                    props = f.get("properties", {})
                    parts = []
                    for key, value in props.items():
                        text = describe(value)
                        if sensitive(name) and not args.show_ids:
                            text = "(ukryte)"
                        parts.append(f"{key}={text}")
                    cmds = command_info(f.get("commands", {}))
                    line = f"        {name}"
                    if parts:
                        line += "  " + "; ".join(parts)
                    if cmds:
                        line += "  >> STEROWANIE: " + " | ".join(cmds)
                    print(line)

    # Historia zdarzeń: tu API może zwracać opisy usterek (errorDescription). Format nie jest
    # nam znany, więc wypisujemy status i strukturę bez żadnych założeń.
    if args.events:
        for inst in installations.get("data", []):
            for gw in inst.get("gateways", []):
                for url in (
                    f"{API}/events-history/installations/{inst['id']}/events?gatewaySerial={gw.get('serial')}",
                    f"{API}/events-history/installations/{inst['id']}/events",
                ):
                    short = url.replace(str(inst["id"]), "<instalacja>").replace(str(gw.get("serial")), "<brama>")
                    try:
                        events, _ = get_json(url, access)
                    except urllib.error.HTTPError as e:
                        print(f"\nZdarzenia {short}: HTTP {e.code} {e.read().decode()[:160]}")
                        continue
                    saved["events"] = events
                    data = events.get("data", events) if isinstance(events, dict) else events
                    items = data if isinstance(data, list) else []
                    print(f"\nZdarzenia {short}: HTTP 200, pozycji: {len(items)}")
                    kinds = {}
                    for ev in items:
                        key = str(ev.get("eventType", ev.get("type", "?")))
                        kinds[key] = kinds.get(key, 0) + 1
                    print("  Rodzaje zdarzeń:", kinds or "brak")
                    for ev in items[:8]:
                        body = ev.get("body", ev)
                        picked = {k: body[k] for k in ("errorCode", "errorDescription", "active", "equipmentType") if k in body}
                        print("  ", ev.get("eventType", "?"), ev.get("eventTimestamp", ""), picked or list(ev.keys()))
                    break

    limit = {k: v for k, v in headers.items() if "ratelimit" in k.lower() or "limit" in k.lower()}
    if limit:
        print("\nNagłówki limitów API:", limit)
    if args.save:
        with open(args.save, "w", encoding="utf-8") as f:
            json.dump(saved, f, indent=1, ensure_ascii=False)
        print(f"\nPełne odpowiedzi zapisane w {args.save} (zawierają numery seryjne, nie udostępniaj).")


if __name__ == "__main__":
    main()
