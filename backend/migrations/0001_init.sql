-- Konta, profile domownikow i sesje.
--
-- Konto to caly dom: jeden adres, jedno haslo. Domownicy to `Profile` pod nim -
-- nie maja wlasnych hasel, tylko opcjonalny PIN, bo to ten sam telefon, ta sama
-- kanapa. Haslo chroni dom przed obcymi, PIN chroni profil przed domownikiem.

CREATE TABLE User (
  id            TEXT PRIMARY KEY,
  email         TEXT NOT NULL UNIQUE,
  passwordHash  TEXT NOT NULL,
  emailVerified INTEGER NOT NULL DEFAULT 0,
  createdAt     TEXT NOT NULL
);

CREATE TABLE Profile (
  id           TEXT PRIMARY KEY,
  userId       TEXT NOT NULL REFERENCES User(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  color        TEXT NOT NULL,
  role         TEXT NOT NULL CHECK (role IN ('admin', 'member', 'restricted')),
  pinHash      TEXT,                 -- NULL = profil bez PIN-u
  permissions  TEXT NOT NULL,        -- JSON, patrz profiles.ts
  allowedRooms TEXT,                 -- JSON z lista identyfikatorow pokoi; NULL = wszystkie
  createdAt    TEXT NOT NULL
);

CREATE INDEX idx_profile_user ON Profile(userId);

-- Tokeny odswiezajace, rotowane przy kazdym uzyciu (jak w Pitstop).
--
-- `profileId` mowi, jako kto urzadzenie jest teraz zalogowane. Znika razem
-- z profilem (SET NULL): sesja zostaje na poziomie konta i aplikacja wraca do
-- ekranu wyboru profilu.
CREATE TABLE RefreshToken (
  tokenHash TEXT PRIMARY KEY,
  userId    TEXT NOT NULL REFERENCES User(id) ON DELETE CASCADE,
  profileId TEXT REFERENCES Profile(id) ON DELETE SET NULL,
  familyId  TEXT NOT NULL,
  expiresAt TEXT NOT NULL,
  usedAt    TEXT,
  createdAt TEXT NOT NULL
);

CREATE INDEX idx_refresh_family ON RefreshToken(familyId);
CREATE INDEX idx_refresh_user ON RefreshToken(userId);

-- Kody jednorazowe: potwierdzenie adresu i reset hasla.
--
-- Jeden wiersz na adres i cel, nowa prosba nadpisuje poprzedni kod.
CREATE TABLE EmailCode (
  email     TEXT NOT NULL,
  purpose   TEXT NOT NULL,           -- 'verify' | 'reset'
  codeHash  TEXT NOT NULL,
  expiresAt TEXT NOT NULL,
  attempts  INTEGER NOT NULL DEFAULT 0,
  sentAt    TEXT NOT NULL,
  PRIMARY KEY (email, purpose)
);

-- Blokada po serii pomylek: `login:<email>` dla hasla, `pin:<profileId>` dla PIN-u.
CREATE TABLE Throttle (
  key         TEXT PRIMARY KEY,
  failures    INTEGER NOT NULL DEFAULT 0,
  lockedUntil TEXT
);
