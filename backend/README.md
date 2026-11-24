# NestIQ API

Cloudflare Worker + D1: konto domu (e-mail i haslo), profile domownikow z rolami
i opcjonalnym PIN-em. Ten sam stos co `pitstop/worker`.

Sterowanie swiatlami i roletami dzieje sie dalej lokalnie (bramka Mobilus, Tuya
LAN). Serwer trzyma tylko konta i profile, wiec **uprawnienia sterowania
egzekwuje aplikacja**; serwer egzekwuje to, co jest jego: kto zarzadza profilami
i PIN-ami.

## Uruchomienie lokalnie

```bash
npm install
npx wrangler d1 migrations apply nestiq --local
npx wrangler dev          # .dev.vars: kody z maila trafiaja do logu
npm run typecheck
```

## Pierwsze wdrozenie

```bash
npx wrangler d1 create nestiq            # wpisz database_id w wrangler.toml
npx wrangler d1 migrations apply nestiq --remote
npx wrangler secret put JWT_SECRET       # min. 32 losowe bajty
npx wrangler secret put RESEND_API_KEY
# ustaw MAIL_FROM w wrangler.toml na zweryfikowana domene w Resend

# Push o wiadomosciach (opcjonalnie): Firebase -> Ustawienia projektu -> Konta uslugowe
# -> Generuj nowy klucz prywatny, potem wklej caly plik JSON:
npx wrangler secret put FCM_SERVICE_ACCOUNT
npx wrangler deploy
```

## Trasy

`POST /v1/push/register` (`token`, `platform`) zapisuje token FCM urzadzenia, a `POST /v1/push/unregister` go usuwa. Wylogowanie kasuje tokeny urzadzenia samo.

Bez tokenu (`POST`, JSON):

| Trasa | Cialo | Wynik |
|---|---|---|
| `/v1/auth/register` | `email`, `password` (8-128) | `verification_required`; kod na maila |
| `/v1/auth/verify` | `email`, `code` | `session` |
| `/v1/auth/resend` | `email` | ponowny kod (raz na minute) |
| `/v1/auth/login` | `email`, `password` | `session`; 403 `email_not_verified` |
| `/v1/auth/refresh` | `refreshToken` | nowa `session` (rotacja) |
| `/v1/auth/sign-out` | `refreshToken` | wylogowanie urzadzenia |
| `/v1/auth/password/forgot` | `email` | zawsze 200; kod na maila |
| `/v1/auth/password/reset` | `email`, `code`, `newPassword` | haslo zmienione, wszystkie urzadzenia wylogowane |

Z `Authorization: Bearer <accessToken>`:

| Trasa | Kto | Dzialanie |
|---|---|---|
| `GET /v1/profiles` | konto | lista profili (ekran wyboru) |
| `POST /v1/profiles` | pierwszy: konto, potem admin | `name`, `color`, `role`, `pin?`, `permissions?`, `allowedRooms?`. Pierwszy profil zawsze admin |
| `PATCH /v1/profiles/:id` | admin | zmiana nazwy, koloru, roli, uprawnien, pokoi |
| `DELETE /v1/profiles/:id` | admin | nie da sie usunac ostatniego admina |
| `POST /v1/profiles/:id/select` | konto | `pin?`; zwraca nowy `accessToken` z wybranym profilem |
| `PUT /v1/profiles/:id/pin` | admin | `pin: "1234"` ustawia, `pin: null` zdejmuje (**reset PIN-u przez admina**) |
| `POST /v1/profiles/:id/pin/recover` | konto + haslo | wyjscie awaryjne, gdy PIN zapomnial jedyny admin |

Role: `admin` (wszystko), `member`, `restricted` (Dziecko: wlacza/wylacza swiatla
i rolety, bez ogrzewania, edycji scen i ustawien). `editScenes` i `manageSettings` ma tylko admin.

Planer domowy (wymaga wybranego profilu w tokenie, inaczej 403 `profile_required`):

| Trasa | Dzialanie |
|---|---|
| `GET/POST /v1/lists`, `PATCH/DELETE /v1/lists/:id` | listy zakupow; widoczne dla wlasciciela i profili z `sharedWith`; zmiana nazwy, udostepnienie i usuniecie tylko wlasciciel |
| `POST /v1/lists/:id/items`, `PATCH/DELETE /v1/lists/:id/items/:itemId`, `POST /v1/lists/:id/clear-checked` | pozycje (kazdy z dostepem) |
| `GET/POST /v1/reminders`, `PATCH/DELETE /v1/reminders/:id`, `POST /v1/reminders/:id/done` | przypomnienia (`kind`, `repeatEvery`/`repeatUnit`, `anchor` fixed/afterDone, `leadDays`, `shared`); `done` przyjmuje `doneOn` |
| `GET/POST /v1/events`, `PATCH/DELETE /v1/events/:id` | kalendarz; `GET` z `from`/`to` (YYYY-MM-DD) |
| `GET/POST /v1/messages`, `POST /v1/messages/read` | wiadomosci do profilu (`to`) albo do wszystkich (`to: null`), max 500 znakow, kasowane po 60 dniach |

Migracja: `migrations/0002_household.sql`. Test dymny: `python3 test/household_smoke.py http://localhost:8799 <log>` przy lokalnym `wrangler dev`.

## Bezpieczenstwo

- Haslo: PBKDF2-SHA256, 100 tys. iteracji (sufit Workers), sol per haslo.
- Blokada na 15 minut po 5 pomylkach: osobno dla hasla (per adres) i PIN-u (per profil).
  Czterocyfrowy PIN chroni wlasnie ta blokada, nie hash, wiec PIN sprawdza sie
  wylacznie na serwerze.
- Tokeny odswiezajace rotowane, ponowne uzycie uniewaznia cala rodzine (jak w Pitstop).
- Rola admina sprawdzana w bazie przy kazdym zadaniu, nie w tokenie.
- Jeszcze nie ma: usuwania konta, testow automatycznych (trasy sprawdzone recznie na lokalnej D1).
