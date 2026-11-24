-- Planer domowy: listy zakupów, przypomnienia, kalendarz i wiadomości między profilami.
--
-- Wszystko należy do konta (domu) i jest tworzone przez konkretny profil. Usunięcie
-- profilu usuwa jego listy, przypomnienia, wydarzenia i wiadomości.

CREATE TABLE ShoppingList (
  id             TEXT PRIMARY KEY,
  userId         TEXT NOT NULL REFERENCES User(id) ON DELETE CASCADE,
  ownerProfileId TEXT NOT NULL REFERENCES Profile(id) ON DELETE CASCADE,
  name           TEXT NOT NULL,
  createdAt      TEXT NOT NULL,
  updatedAt      TEXT NOT NULL
);
CREATE INDEX idx_list_user ON ShoppingList(userId);

-- Lista widoczna jest dla właściciela i profili, którym ją udostępniono.
CREATE TABLE ShoppingListShare (
  listId    TEXT NOT NULL REFERENCES ShoppingList(id) ON DELETE CASCADE,
  profileId TEXT NOT NULL REFERENCES Profile(id) ON DELETE CASCADE,
  PRIMARY KEY (listId, profileId)
);
CREATE INDEX idx_share_profile ON ShoppingListShare(profileId);

CREATE TABLE ShoppingItem (
  id                 TEXT PRIMARY KEY,
  listId             TEXT NOT NULL REFERENCES ShoppingList(id) ON DELETE CASCADE,
  text               TEXT NOT NULL,
  quantity           TEXT,
  checked            INTEGER NOT NULL DEFAULT 0,
  checkedByProfileId TEXT REFERENCES Profile(id) ON DELETE SET NULL,
  addedByProfileId   TEXT REFERENCES Profile(id) ON DELETE SET NULL,
  position           INTEGER NOT NULL,
  createdAt          TEXT NOT NULL,
  updatedAt          TEXT NOT NULL
);
CREATE INDEX idx_item_list ON ShoppingItem(listId);

-- Przypomnienia cykliczne (filtr do wody, ekspres, ubezpieczenie, urodziny).
--   date        najbliższy termin, YYYY-MM-DD
--   repeatEvery 0 = jednorazowe; w przeciwnym razie co tyle jednostek `repeatUnit`
--   anchor      'fixed'     = kolejny termin liczony od poprzedniego (urodziny, polisa)
--               'afterDone' = od dnia wykonania (filtr, czyszczenie)
--   leadDays    ile dni wcześniej przypomnieć (urodziny: 7)
CREATE TABLE Reminder (
  id             TEXT PRIMARY KEY,
  userId         TEXT NOT NULL REFERENCES User(id) ON DELETE CASCADE,
  ownerProfileId TEXT NOT NULL REFERENCES Profile(id) ON DELETE CASCADE,
  kind           TEXT NOT NULL CHECK (kind IN ('water_filter', 'coffee_clean', 'insurance', 'birthday', 'custom')),
  title          TEXT NOT NULL,
  note           TEXT,
  date           TEXT NOT NULL,
  repeatEvery    INTEGER NOT NULL DEFAULT 0,
  repeatUnit     TEXT NOT NULL DEFAULT 'month' CHECK (repeatUnit IN ('day', 'month', 'year')),
  anchor         TEXT NOT NULL DEFAULT 'fixed' CHECK (anchor IN ('fixed', 'afterDone')),
  leadDays       INTEGER NOT NULL DEFAULT 0,
  shared         INTEGER NOT NULL DEFAULT 1,
  completedAt    TEXT,
  createdAt      TEXT NOT NULL,
  updatedAt      TEXT NOT NULL
);
CREATE INDEX idx_reminder_user ON Reminder(userId);

CREATE TABLE CalendarEvent (
  id             TEXT PRIMARY KEY,
  userId         TEXT NOT NULL REFERENCES User(id) ON DELETE CASCADE,
  ownerProfileId TEXT NOT NULL REFERENCES Profile(id) ON DELETE CASCADE,
  title          TEXT NOT NULL,
  note           TEXT,
  startsAt       TEXT NOT NULL,   -- YYYY-MM-DD albo YYYY-MM-DDTHH:MM (czas lokalny domu)
  endsAt         TEXT,
  allDay         INTEGER NOT NULL DEFAULT 0,
  shared         INTEGER NOT NULL DEFAULT 1,
  createdAt      TEXT NOT NULL,
  updatedAt      TEXT NOT NULL
);
CREATE INDEX idx_event_user ON CalendarEvent(userId, startsAt);

-- Wiadomość do jednego profilu (toProfileId) albo do wszystkich (NULL).
CREATE TABLE Message (
  id            TEXT PRIMARY KEY,
  userId        TEXT NOT NULL REFERENCES User(id) ON DELETE CASCADE,
  fromProfileId TEXT NOT NULL REFERENCES Profile(id) ON DELETE CASCADE,
  toProfileId   TEXT REFERENCES Profile(id) ON DELETE CASCADE,
  body          TEXT NOT NULL,
  createdAt     TEXT NOT NULL
);
CREATE INDEX idx_message_user ON Message(userId, createdAt);

CREATE TABLE MessageRead (
  messageId TEXT NOT NULL REFERENCES Message(id) ON DELETE CASCADE,
  profileId TEXT NOT NULL REFERENCES Profile(id) ON DELETE CASCADE,
  readAt    TEXT NOT NULL,
  PRIMARY KEY (messageId, profileId)
);
