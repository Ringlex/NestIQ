#!/usr/bin/env python3
"""Test przepływu planera domowego na lokalnym `wrangler dev` (patrz README).

  npx wrangler d1 migrations apply nestiq --local
  npx wrangler dev --port 8799 > /tmp/nestiq-dev.log 2>&1 &
  python3 test/household_smoke.py http://localhost:8799 /tmp/nestiq-dev.log
"""
import json, re, sys, time, urllib.error, urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8799"
LOG = sys.argv[2] if len(sys.argv) > 2 else "/tmp/nestiq-dev.log"
failures = []


def call(method, path, body=None, token=None):
    req = urllib.request.Request(
        BASE + path, method=method, data=None if body is None else json.dumps(body).encode(),
        headers={"content-type": "application/json", **({"authorization": "Bearer " + token} if token else {})})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


def check(name, condition, detail=""):
    print(("OK   " if condition else "FAIL ") + name + ("" if condition else f"  {detail}"))
    if not condition:
        failures.append(name)


email = f"plan{int(time.time())}@wp.pl"
call("POST", "/v1/auth/register", {"email": email, "password": "haslo12345"})
time.sleep(1)
code = re.findall(r"(\d{6}) - kod potwierdzajacy", open(LOG).read())[-1]
account = call("POST", "/v1/auth/verify", {"email": email, "code": code})[1]["session"]["accessToken"]

s, first = call("POST", "/v1/profiles", {"name": "Mama", "color": "#B9EBF3"}, account)
mama_t = first["accessToken"]
mama = first["profile"]["id"]
_, kid_r = call("POST", "/v1/profiles", {"name": "Dziecko", "color": "#D9E3F8", "role": "restricted"}, mama_t)
_, gran_r = call("POST", "/v1/profiles", {"name": "Babcia", "color": "#FFE3A8", "role": "member"}, mama_t)
kid, gran = kid_r["profile"]["id"], gran_r["profile"]["id"]
kid_t = call("POST", f"/v1/profiles/{kid}/select", {}, account)[1]["accessToken"]
gran_t = call("POST", f"/v1/profiles/{gran}/select", {}, account)[1]["accessToken"]

print("--- bez wybranego profilu")
check("lista wymaga profilu", call("GET", "/v1/lists", None, account)[0] == 403)

print("--- listy zakupów")
s, r = call("POST", "/v1/lists", {"name": "Spożywcze", "sharedWith": [kid]}, mama_t)
check("utworzenie listy", s == 201, r)
shop = r["id"]
_, priv = call("POST", "/v1/lists", {"name": "Prezenty (tajne)"}, mama_t)
lists = lambda t: call("GET", "/v1/lists", None, t)[1]["lists"]
check("właściciel widzi obie listy", len(lists(mama_t)) == 2)
check("dziecko widzi tylko udostępnioną", [l["name"] for l in lists(kid_t)] == ["Spożywcze"])
check("babcia nie widzi żadnej", lists(gran_t) == [])
check("nieudostępniona lista jest dla innych 404", call("POST", f"/v1/lists/{priv['id']}/items", {"text": "x"}, kid_t)[0] == 404)

s, it = call("POST", f"/v1/lists/{shop}/items", {"text": "Mleko", "quantity": "2 l"}, mama_t)
check("dodanie pozycji", s == 201)
call("POST", f"/v1/lists/{shop}/items", {"text": "Chleb"}, kid_t)
check("dziecko dodaje do udostępnionej listy", len(lists(mama_t)[0]["items"]) == 2)
check("pozycja bez tekstu odrzucona", call("POST", f"/v1/lists/{shop}/items", {"text": "  "}, mama_t)[0] == 400)
call("PATCH", f"/v1/lists/{shop}/items/{it['id']}", {"checked": True}, kid_t)
milk = [i for i in lists(mama_t)[0]["items"] if i["text"] == "Mleko"][0]
check("odhaczenie zapamiętuje kto kupił", milk["checked"] and milk["checkedBy"] == kid, milk)
check("dziecko nie zmieni nazwy ani udostępnienia", call("PATCH", f"/v1/lists/{shop}", {"name": "X"}, kid_t)[0] == 403)
check("dziecko nie usunie cudzej listy", call("DELETE", f"/v1/lists/{shop}", None, kid_t)[0] == 403)
check("udostępnienie nieistniejącemu profilowi odrzucone", call("PATCH", f"/v1/lists/{shop}", {"sharedWith": ["00000000-0000-0000-0000-000000000000"]}, mama_t)[0] == 400)
call("PATCH", f"/v1/lists/{shop}", {"sharedWith": [kid, gran]}, mama_t)
check("po udostępnieniu babcia widzi listę", [l["name"] for l in lists(gran_t)] == ["Spożywcze"])
call("POST", f"/v1/lists/{shop}/clear-checked", None, gran_t)
check("usunięcie kupionych zostawia resztę", [i["text"] for i in lists(mama_t)[0]["items"]] == ["Chleb"])
call("PATCH", f"/v1/lists/{shop}", {"sharedWith": []}, mama_t)
check("cofnięcie udostępnienia chowa listę", lists(kid_t) == [])

print("--- przypomnienia")
s, r = call("POST", "/v1/reminders", {"kind": "water_filter", "title": "Wymiana filtra do wody", "date": "2026-10-01",
                                      "repeatEvery": 3, "repeatUnit": "month", "anchor": "afterDone", "leadDays": 3}, mama_t)
check("utworzenie przypomnienia", s == 201, r)
filt = r["id"]
_, b = call("POST", "/v1/reminders", {"kind": "birthday", "title": "Urodziny Ani", "date": "2026-03-14",
                                      "repeatEvery": 1, "repeatUnit": "year", "anchor": "fixed", "leadDays": 7}, mama_t)
_, secret = call("POST", "/v1/reminders", {"title": "Tajne", "date": "2026-12-01", "shared": False}, mama_t)
rem = lambda t: call("GET", "/v1/reminders", None, t)[1]["reminders"]
check("wspólne widzą wszyscy, prywatne tylko autor", len(rem(mama_t)) == 3 and len(rem(kid_t)) == 2)
check("zła data odrzucona", call("POST", "/v1/reminders", {"title": "x", "date": "2026-02-30"}, mama_t)[0] == 400)
check("zły rodzaj odrzucony", call("POST", "/v1/reminders", {"title": "x", "date": "2026-02-01", "kind": "zly"}, mama_t)[0] == 400)
_, done = call("POST", f"/v1/reminders/{filt}/done", {"doneOn": "2026-10-27"}, kid_t)
check("filtr wymieniony 27.10 -> kolejny za 3 miesiące od tego dnia", done.get("next") == "2027-01-27", done)
_, done = call("POST", f"/v1/reminders/{b['id']}/done", {"doneOn": "2026-03-20"}, gran_t)
check("urodziny odhaczone po terminie -> za rok, ten sam dzień", done.get("next") == "2027-03-14", done)
check("cudzego przypomnienia nie usunie dziecko", call("DELETE", f"/v1/reminders/{filt}", None, kid_t)[0] == 403)
check("prywatnego przypomnienia nie widać dla innych", call("POST", f"/v1/reminders/{secret['id']}/done", {}, kid_t)[0] == 404)
_, once = call("POST", "/v1/reminders", {"title": "Jednorazowe", "date": "2026-11-01"}, mama_t)
_, done = call("POST", f"/v1/reminders/{once['id']}/done", {"doneOn": "2026-11-01"}, mama_t)
check("jednorazowe kończy się po odhaczeniu", done.get("completed") is True, done)

print("--- kalendarz")
s, ev = call("POST", "/v1/events", {"title": "Dentysta", "startsAt": "2026-11-05T15:30", "endsAt": "2026-11-05T16:30"}, mama_t)
check("utworzenie wydarzenia", s == 201, ev)
call("POST", "/v1/events", {"title": "Urlop", "startsAt": "2026-11-20", "endsAt": "2026-11-25", "allDay": True}, mama_t)
evs = lambda q, t=mama_t: call("GET", "/v1/events" + q, None, t)[1]["events"]
check("zakres listopada zawiera oba", len(evs("?from=2026-11-01&to=2026-11-30")) == 2)
check("wydarzenie wielodniowe łapie się w środku zakresu", len(evs("?from=2026-11-22&to=2026-11-22")) == 1)
check("poza zakresem pusto", evs("?from=2026-12-01&to=2026-12-31") == [])
check("koniec przed początkiem odrzucony", call("POST", "/v1/events", {"title": "x", "startsAt": "2026-11-05T10:00", "endsAt": "2026-11-05T09:00"}, mama_t)[0] == 400)
check("całodniowe nie ma godziny", evs("?from=2026-11-20&to=2026-11-20")[0]["startsAt"] == "2026-11-20")

print("--- wiadomości")
s, m1 = call("POST", "/v1/messages", {"to": kid, "body": "Hej, wychodzę po pracy z koleżanką na kawę, wrócę później"}, mama_t)
check("wysłanie do jednego profilu", s == 201, m1)
call("POST", "/v1/messages", {"to": None, "body": "Obiad o 18"}, mama_t)
inbox = lambda t: call("GET", "/v1/messages", None, t)[1]
check("dziecko ma 2 nieprzeczytane", inbox(kid_t)["unread"] == 2)
check("babcia widzi tylko wiadomość do wszystkich", [m["body"] for m in inbox(gran_t)["messages"]] == ["Obiad o 18"])
check("nadawca widzi swoje wiadomości jako przeczytane", inbox(mama_t)["unread"] == 0 and len(inbox(mama_t)["messages"]) == 2)
call("POST", "/v1/messages/read", {"ids": [m1["id"]]}, kid_t)
check("oznaczenie jednej jako przeczytanej", inbox(kid_t)["unread"] == 1)
call("POST", "/v1/messages/read", {"all": True}, kid_t)
check("oznaczenie wszystkich", inbox(kid_t)["unread"] == 0 and inbox(gran_t)["unread"] == 1, "stan czytania jest per profil")
check("do samego siebie nie można", call("POST", "/v1/messages", {"to": mama, "body": "x"}, mama_t)[0] == 400)
check("pusta wiadomość odrzucona", call("POST", "/v1/messages", {"body": " "}, mama_t)[0] == 400)
check("zbyt długa wiadomość odrzucona", call("POST", "/v1/messages", {"body": "a" * 501}, mama_t)[0] == 400)

print("--- sprzątanie po usunięciu profilu")
call("DELETE", f"/v1/profiles/{gran}", None, mama_t)
check("usunięcie profilu nie psuje list pozostałych", len(lists(mama_t)) == 2)
check("wiadomość od usuniętego profilu znika, reszta zostaje", len(inbox(mama_t)["messages"]) == 2)

print()
print("PORAŻKI:" if failures else "WSZYSTKO OK", failures or "")
sys.exit(1 if failures else 0)
