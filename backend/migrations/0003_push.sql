-- Tokeny FCM urzadzen, zeby wiadomosci docieraly takze przy zamknietej aplikacji.
--
-- Urzadzenie to rodzina tokenu odswiezajacego (`familyId`), a to, jako kto jest
-- ono teraz zalogowane, mowi RefreshToken.profileId. Dzieki temu powiadomienie
-- trafia na telefon tego domownika, do ktorego wiadomosc jest adresowana, a nie
-- na kazdy telefon na koncie.
CREATE TABLE PushToken (
  token     TEXT PRIMARY KEY,
  userId    TEXT NOT NULL REFERENCES User(id) ON DELETE CASCADE,
  familyId  TEXT NOT NULL,
  platform  TEXT NOT NULL CHECK (platform IN ('android', 'ios')),
  updatedAt TEXT NOT NULL
);

CREATE INDEX idx_push_family ON PushToken(familyId);
CREATE INDEX idx_push_user ON PushToken(userId);
