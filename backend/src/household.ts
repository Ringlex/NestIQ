import type { AccessClaims } from './auth';
import { isDate, isDateTime, nextDue, type RepeatUnit } from './dates';
import type { Env } from './env';
import { pushToHousehold } from './push';
import { fail, nowIso, type Result } from './util';

/**
 * Planer domowy: listy zakupow, przypomnienia, kalendarz, wiadomosci.
 *
 * Wszystko dzieje sie w imieniu wybranego profilu (token niesie `pid`), a dane naleza
 * do konta. Dostep sprawdzamy zawsze w bazie, nie w tokenie.
 */

interface Actor {
  id: string;
  userId: string;
  role: string;
}

async function actor(env: Env, claims: AccessClaims): Promise<Actor | null> {
  if (!claims.profileId) {
    return null;
  }

  return env.DB.prepare('SELECT id, userId, role FROM Profile WHERE id = ? AND userId = ?')
    .bind(claims.profileId, claims.userId)
    .first<Actor>();
}

const NO_PROFILE = (): Result => fail(403, 'profile_required');

function text(value: unknown, max: number, { required = true }: { required?: boolean } = {}): string | null | undefined {
  if (value === undefined) {
    return undefined;
  }

  if (value === null || (typeof value === 'string' && value.trim() === '')) {
    return required ? null : '';
  }

  return typeof value === 'string' && value.trim().length <= max ? value.trim() : null;
}

async function profilesOfUser(env: Env, userId: string, ids: string[]): Promise<boolean> {
  if (ids.length === 0) {
    return true;
  }

  const { results } = await env.DB.prepare(
    `SELECT id FROM Profile WHERE userId = ? AND id IN (${ids.map(() => '?').join(',')})`,
  )
    .bind(userId, ...ids)
    .all<{ id: string }>();

  return results.length === new Set(ids).size;
}

// ---------------------------------------------------------------------------
// Listy zakupow
// ---------------------------------------------------------------------------

const MAX_LISTS = 30;
const MAX_ITEMS = 300;
const MAX_SHARES = 8;

interface ListRow {
  id: string;
  userId: string;
  ownerProfileId: string;
  name: string;
  createdAt: string;
  updatedAt: string;
}

interface ItemRow {
  id: string;
  listId: string;
  text: string;
  quantity: string | null;
  checked: number;
  checkedByProfileId: string | null;
  addedByProfileId: string | null;
  position: number;
}

const VISIBLE_LIST = `l.userId = ? AND (l.ownerProfileId = ? OR l.id IN (SELECT listId FROM ShoppingListShare WHERE profileId = ?))`;

async function accessibleList(env: Env, me: Actor, listId: string): Promise<ListRow | null> {
  return env.DB.prepare(`SELECT l.* FROM ShoppingList l WHERE l.id = ? AND ${VISIBLE_LIST}`)
    .bind(listId, me.userId, me.id, me.id)
    .first<ListRow>();
}

function itemJson(row: ItemRow): Record<string, unknown> {
  return {
    id: row.id,
    text: row.text,
    quantity: row.quantity,
    checked: row.checked === 1,
    checkedBy: row.checkedByProfileId,
    addedBy: row.addedByProfileId,
    position: row.position,
  };
}

export async function handleListLists(env: Env, claims: AccessClaims): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const [lists, items, shares] = await Promise.all([
    env.DB.prepare(`SELECT l.* FROM ShoppingList l WHERE ${VISIBLE_LIST} ORDER BY l.createdAt`)
      .bind(me.userId, me.id, me.id)
      .all<ListRow>(),
    env.DB.prepare(
      `SELECT i.* FROM ShoppingItem i JOIN ShoppingList l ON l.id = i.listId
       WHERE ${VISIBLE_LIST} ORDER BY i.position`,
    )
      .bind(me.userId, me.id, me.id)
      .all<ItemRow>(),
    env.DB.prepare(
      `SELECT s.listId AS listId, s.profileId AS profileId FROM ShoppingListShare s
       JOIN ShoppingList l ON l.id = s.listId WHERE ${VISIBLE_LIST}`,
    )
      .bind(me.userId, me.id, me.id)
      .all<{ listId: string; profileId: string }>(),
  ]);

  return {
    status: 200,
    body: {
      lists: lists.results.map((l) => ({
        id: l.id,
        name: l.name,
        ownerProfileId: l.ownerProfileId,
        sharedWith: shares.results.filter((s) => s.listId === l.id).map((s) => s.profileId),
        items: items.results.filter((i) => i.listId === l.id).map(itemJson),
        updatedAt: l.updatedAt,
      })),
    },
  };
}

function parseShares(value: unknown, ownerId: string): string[] | null | undefined {
  if (value === undefined) {
    return undefined;
  }

  if (!Array.isArray(value) || value.length > MAX_SHARES || !value.every((v) => typeof v === 'string')) {
    return null;
  }

  return [...new Set(value as string[])].filter((id) => id !== ownerId);
}

export async function handleCreateList(env: Env, claims: AccessClaims, body: Record<string, unknown>): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const name = text(body.name, 60);
  const shares = parseShares(body.sharedWith, me.id) ?? [];

  if (!name || shares === null) {
    return fail(400, 'invalid_request');
  }

  const count = await env.DB.prepare('SELECT COUNT(*) AS c FROM ShoppingList WHERE userId = ?')
    .bind(me.userId)
    .first<{ c: number }>();

  if ((count?.c ?? 0) >= MAX_LISTS) {
    return fail(409, 'too_many_lists');
  }

  if (!(await profilesOfUser(env, me.userId, shares))) {
    return fail(400, 'invalid_share');
  }

  const id = crypto.randomUUID();
  const now = nowIso();

  await env.DB.batch([
    env.DB.prepare(
      'INSERT INTO ShoppingList (id, userId, ownerProfileId, name, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)',
    ).bind(id, me.userId, me.id, name, now, now),
    ...shares.map((profileId) =>
      env.DB.prepare('INSERT INTO ShoppingListShare (listId, profileId) VALUES (?, ?)').bind(id, profileId),
    ),
  ]);

  return { status: 201, body: { id } };
}

export async function handleUpdateList(
  env: Env,
  claims: AccessClaims,
  id: string,
  body: Record<string, unknown>,
): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const list = await accessibleList(env, me, id);

  if (!list) {
    return fail(404, 'not_found');
  }

  // Nazwe i udostepnianie zmienia wlasciciel; reszta profili tylko korzysta z listy.
  if (list.ownerProfileId !== me.id) {
    return fail(403, 'owner_required');
  }

  const name = text(body.name, 60);
  const shares = parseShares(body.sharedWith, me.id);

  if (name === null || shares === null || (body.name !== undefined && !name)) {
    return fail(400, 'invalid_request');
  }

  if (shares && !(await profilesOfUser(env, me.userId, shares))) {
    return fail(400, 'invalid_share');
  }

  const statements = [
    env.DB.prepare('UPDATE ShoppingList SET name = ?, updatedAt = ? WHERE id = ?').bind(name ?? list.name, nowIso(), id),
  ];

  if (shares) {
    statements.push(env.DB.prepare('DELETE FROM ShoppingListShare WHERE listId = ?').bind(id));
    for (const profileId of shares) {
      statements.push(
        env.DB.prepare('INSERT INTO ShoppingListShare (listId, profileId) VALUES (?, ?)').bind(id, profileId),
      );
    }
  }

  await env.DB.batch(statements);

  return { status: 200, body: { status: 'ok' } };
}

export async function handleDeleteList(env: Env, claims: AccessClaims, id: string): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const list = await accessibleList(env, me, id);

  if (!list) {
    return fail(404, 'not_found');
  }

  if (list.ownerProfileId !== me.id) {
    return fail(403, 'owner_required');
  }

  await env.DB.prepare('DELETE FROM ShoppingList WHERE id = ?').bind(id).run();

  return { status: 200, body: { status: 'ok' } };
}

export async function handleAddItem(
  env: Env,
  claims: AccessClaims,
  listId: string,
  body: Record<string, unknown>,
): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const list = await accessibleList(env, me, listId);

  if (!list) {
    return fail(404, 'not_found');
  }

  const itemText = text(body.text, 100);
  const quantity = text(body.quantity, 30, { required: false });

  if (!itemText || quantity === null) {
    return fail(400, 'invalid_request');
  }

  const stats = await env.DB.prepare('SELECT COUNT(*) AS c, COALESCE(MAX(position), 0) AS p FROM ShoppingItem WHERE listId = ?')
    .bind(listId)
    .first<{ c: number; p: number }>();

  if ((stats?.c ?? 0) >= MAX_ITEMS) {
    return fail(409, 'too_many_items');
  }

  const id = crypto.randomUUID();
  const now = nowIso();

  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO ShoppingItem (id, listId, text, quantity, checked, addedByProfileId, position, createdAt, updatedAt)
       VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?)`,
    ).bind(id, listId, itemText, quantity || null, me.id, (stats?.p ?? 0) + 1, now, now),
    env.DB.prepare('UPDATE ShoppingList SET updatedAt = ? WHERE id = ?').bind(now, listId),
  ]);

  return { status: 201, body: { id } };
}

export async function handleUpdateItem(
  env: Env,
  claims: AccessClaims,
  listId: string,
  itemId: string,
  body: Record<string, unknown>,
): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  if (!(await accessibleList(env, me, listId))) {
    return fail(404, 'not_found');
  }

  const item = await env.DB.prepare('SELECT * FROM ShoppingItem WHERE id = ? AND listId = ?')
    .bind(itemId, listId)
    .first<ItemRow>();

  if (!item) {
    return fail(404, 'not_found');
  }

  const itemText = text(body.text, 100);
  const quantity = text(body.quantity, 30, { required: false });

  if (itemText === null || quantity === null || (body.checked !== undefined && typeof body.checked !== 'boolean')) {
    return fail(400, 'invalid_request');
  }

  const checked = body.checked === undefined ? item.checked === 1 : (body.checked as boolean);
  const now = nowIso();

  await env.DB.batch([
    env.DB.prepare(
      `UPDATE ShoppingItem SET text = ?, quantity = ?, checked = ?, checkedByProfileId = ?, updatedAt = ? WHERE id = ?`,
    ).bind(
      itemText ?? item.text,
      quantity === undefined ? item.quantity : quantity || null,
      checked ? 1 : 0,
      checked ? (item.checked === 1 ? item.checkedByProfileId : me.id) : null,
      now,
      itemId,
    ),
    env.DB.prepare('UPDATE ShoppingList SET updatedAt = ? WHERE id = ?').bind(now, listId),
  ]);

  return { status: 200, body: { status: 'ok' } };
}

export async function handleDeleteItem(env: Env, claims: AccessClaims, listId: string, itemId: string): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  if (!(await accessibleList(env, me, listId))) {
    return fail(404, 'not_found');
  }

  await env.DB.batch([
    env.DB.prepare('DELETE FROM ShoppingItem WHERE id = ? AND listId = ?').bind(itemId, listId),
    env.DB.prepare('UPDATE ShoppingList SET updatedAt = ? WHERE id = ?').bind(nowIso(), listId),
  ]);

  return { status: 200, body: { status: 'ok' } };
}

/** Usuwa kupione pozycje, zostawia reszte listy. */
export async function handleClearChecked(env: Env, claims: AccessClaims, listId: string): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  if (!(await accessibleList(env, me, listId))) {
    return fail(404, 'not_found');
  }

  await env.DB.batch([
    env.DB.prepare('DELETE FROM ShoppingItem WHERE listId = ? AND checked = 1').bind(listId),
    env.DB.prepare('UPDATE ShoppingList SET updatedAt = ? WHERE id = ?').bind(nowIso(), listId),
  ]);

  return { status: 200, body: { status: 'ok' } };
}

// ---------------------------------------------------------------------------
// Przypomnienia
// ---------------------------------------------------------------------------

const KINDS = ['water_filter', 'coffee_clean', 'insurance', 'birthday', 'custom'] as const;
const UNITS: readonly RepeatUnit[] = ['day', 'month', 'year'];
const MAX_REMINDERS = 200;

interface ReminderRow {
  id: string;
  userId: string;
  ownerProfileId: string;
  kind: string;
  title: string;
  note: string | null;
  date: string;
  repeatEvery: number;
  repeatUnit: RepeatUnit;
  anchor: 'fixed' | 'afterDone';
  leadDays: number;
  shared: number;
  completedAt: string | null;
}

function reminderJson(r: ReminderRow): Record<string, unknown> {
  return {
    id: r.id,
    ownerProfileId: r.ownerProfileId,
    kind: r.kind,
    title: r.title,
    note: r.note,
    date: r.date,
    repeatEvery: r.repeatEvery,
    repeatUnit: r.repeatUnit,
    anchor: r.anchor,
    leadDays: r.leadDays,
    shared: r.shared === 1,
    completedAt: r.completedAt,
  };
}

interface ReminderInput {
  kind: string;
  title: string;
  note: string | null;
  date: string;
  repeatEvery: number;
  repeatUnit: RepeatUnit;
  anchor: 'fixed' | 'afterDone';
  leadDays: number;
  shared: boolean;
}

/** Laczy nadeslane pola z istniejacym przypomnieniem (przy tworzeniu: z domyslnymi) i waliduje calosc. */
function mergeReminder(body: Record<string, unknown>, base: ReminderRow | null): ReminderInput | null {
  const title = text(body.title, 80);
  const note = text(body.note, 300, { required: false });

  const input = {
    kind: body.kind ?? base?.kind ?? 'custom',
    title: title ?? base?.title,
    note: note === undefined ? (base?.note ?? null) : note || null,
    date: body.date ?? base?.date,
    repeatEvery: body.repeatEvery ?? base?.repeatEvery ?? 0,
    repeatUnit: body.repeatUnit ?? base?.repeatUnit ?? 'month',
    anchor: body.anchor ?? base?.anchor ?? 'fixed',
    leadDays: body.leadDays ?? base?.leadDays ?? 0,
    shared: body.shared ?? (base ? base.shared === 1 : true),
  };

  if (
    title === null ||
    note === null ||
    typeof input.title !== 'string' ||
    !(KINDS as readonly unknown[]).includes(input.kind) ||
    !isDate(input.date) ||
    !Number.isInteger(input.repeatEvery) ||
    (input.repeatEvery as number) < 0 ||
    (input.repeatEvery as number) > 120 ||
    !(UNITS as readonly unknown[]).includes(input.repeatUnit) ||
    (input.anchor !== 'fixed' && input.anchor !== 'afterDone') ||
    !Number.isInteger(input.leadDays) ||
    (input.leadDays as number) < 0 ||
    (input.leadDays as number) > 60 ||
    typeof input.shared !== 'boolean'
  ) {
    return null;
  }

  return input as ReminderInput;
}

export async function handleListReminders(env: Env, claims: AccessClaims): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const { results } = await env.DB.prepare(
    'SELECT * FROM Reminder WHERE userId = ? AND (shared = 1 OR ownerProfileId = ?) ORDER BY date',
  )
    .bind(me.userId, me.id)
    .all<ReminderRow>();

  return { status: 200, body: { reminders: results.map(reminderJson) } };
}

export async function handleCreateReminder(env: Env, claims: AccessClaims, body: Record<string, unknown>): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const input = mergeReminder(body, null);

  if (!input || body.title === undefined || body.date === undefined) {
    return fail(400, 'invalid_request');
  }

  const count = await env.DB.prepare('SELECT COUNT(*) AS c FROM Reminder WHERE userId = ?').bind(me.userId).first<{ c: number }>();

  if ((count?.c ?? 0) >= MAX_REMINDERS) {
    return fail(409, 'too_many_reminders');
  }

  const id = crypto.randomUUID();
  const now = nowIso();

  await env.DB.prepare(
    `INSERT INTO Reminder (id, userId, ownerProfileId, kind, title, note, date, repeatEvery, repeatUnit, anchor,
       leadDays, shared, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      id, me.userId, me.id, input.kind, input.title, input.note, input.date, input.repeatEvery,
      input.repeatUnit, input.anchor, input.leadDays, input.shared ? 1 : 0, now, now,
    )
    .run();

  return { status: 201, body: { id } };
}

async function visibleReminder(env: Env, me: Actor, id: string): Promise<ReminderRow | null> {
  return env.DB.prepare('SELECT * FROM Reminder WHERE id = ? AND userId = ? AND (shared = 1 OR ownerProfileId = ?)')
    .bind(id, me.userId, me.id)
    .first<ReminderRow>();
}

export async function handleUpdateReminder(
  env: Env,
  claims: AccessClaims,
  id: string,
  body: Record<string, unknown>,
): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const current = await visibleReminder(env, me, id);

  if (!current) {
    return fail(404, 'not_found');
  }

  if (current.ownerProfileId !== me.id && me.role !== 'admin') {
    return fail(403, 'owner_required');
  }

  const input = mergeReminder(body, current);

  if (!input) {
    return fail(400, 'invalid_request');
  }

  await env.DB.prepare(
    `UPDATE Reminder SET kind = ?, title = ?, note = ?, date = ?, repeatEvery = ?, repeatUnit = ?, anchor = ?,
       leadDays = ?, shared = ?, completedAt = NULL, updatedAt = ? WHERE id = ?`,
  )
    .bind(
      input.kind, input.title, input.note, input.date, input.repeatEvery, input.repeatUnit, input.anchor,
      input.leadDays, input.shared ? 1 : 0, nowIso(), id,
    )
    .run();

  return { status: 200, body: { status: 'ok' } };
}

export async function handleDeleteReminder(env: Env, claims: AccessClaims, id: string): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const current = await visibleReminder(env, me, id);

  if (!current) {
    return fail(404, 'not_found');
  }

  if (current.ownerProfileId !== me.id && me.role !== 'admin') {
    return fail(403, 'owner_required');
  }

  await env.DB.prepare('DELETE FROM Reminder WHERE id = ?').bind(id).run();

  return { status: 200, body: { status: 'ok' } };
}

/**
 * Odhaczenie ("wymienione", "zrobione"): wylicza kolejny termin. Moze to zrobic kazdy,
 * kto przypomnienie widzi, bo w domu filtr wymienia ten, kto akurat jest w domu.
 * `doneOn` podaje telefon (jego lokalny dzien), a nie serwer w UTC.
 */
export async function handleCompleteReminder(
  env: Env,
  claims: AccessClaims,
  id: string,
  body: Record<string, unknown>,
): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const current = await visibleReminder(env, me, id);

  if (!current) {
    return fail(404, 'not_found');
  }

  const doneOn = body.doneOn ?? new Date().toISOString().slice(0, 10);

  if (!isDate(doneOn)) {
    return fail(400, 'invalid_request');
  }

  const next = nextDue(current, doneOn);

  if (next) {
    await env.DB.prepare('UPDATE Reminder SET date = ?, completedAt = NULL, updatedAt = ? WHERE id = ?')
      .bind(next, nowIso(), id)
      .run();
  } else {
    await env.DB.prepare('UPDATE Reminder SET completedAt = ?, updatedAt = ? WHERE id = ?')
      .bind(nowIso(), nowIso(), id)
      .run();
  }

  return { status: 200, body: { next, completed: next === null } };
}

// ---------------------------------------------------------------------------
// Kalendarz
// ---------------------------------------------------------------------------

const MAX_EVENTS = 1000;

interface EventRow {
  id: string;
  userId: string;
  ownerProfileId: string;
  title: string;
  note: string | null;
  startsAt: string;
  endsAt: string | null;
  allDay: number;
  shared: number;
}

function eventJson(e: EventRow): Record<string, unknown> {
  return {
    id: e.id,
    ownerProfileId: e.ownerProfileId,
    title: e.title,
    note: e.note,
    startsAt: e.startsAt,
    endsAt: e.endsAt,
    allDay: e.allDay === 1,
    shared: e.shared === 1,
  };
}

function mergeEvent(body: Record<string, unknown>, base: EventRow | null) {
  const title = text(body.title, 80);
  const note = text(body.note, 300, { required: false });
  const allDay = body.allDay ?? (base ? base.allDay === 1 : false);
  const startsAt = body.startsAt ?? base?.startsAt;
  const endsAtRaw = body.endsAt === undefined ? (base?.endsAt ?? null) : body.endsAt;
  const shared = body.shared ?? (base ? base.shared === 1 : true);

  if (
    title === null ||
    note === null ||
    typeof allDay !== 'boolean' ||
    typeof shared !== 'boolean' ||
    !isDateTime(startsAt) ||
    (endsAtRaw !== null && !isDateTime(endsAtRaw))
  ) {
    return null;
  }

  const finalTitle = title ?? base?.title;

  if (!finalTitle) {
    return null;
  }

  // Wydarzenie calodniowe trzyma same daty, zeby nie mialo godziny, ktorej nikt nie wybral.
  const normalize = (v: string): string => (allDay ? v.slice(0, 10) : v);
  const start = normalize(startsAt);
  const end = endsAtRaw === null ? null : normalize(endsAtRaw);

  if (end !== null && end < start) {
    return null;
  }

  return {
    title: finalTitle,
    note: note === undefined ? (base?.note ?? null) : note || null,
    startsAt: start,
    endsAt: end,
    allDay,
    shared,
  };
}

export async function handleListEvents(env: Env, claims: AccessClaims, query: URLSearchParams): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const from = query.get('from') ?? '0000-01-01';
  const to = query.get('to') ?? '9999-12-31';

  if (!isDate(from) || !isDate(to)) {
    return fail(400, 'invalid_request');
  }

  const { results } = await env.DB.prepare(
    `SELECT * FROM CalendarEvent WHERE userId = ? AND (shared = 1 OR ownerProfileId = ?)
       AND substr(startsAt, 1, 10) <= ? AND COALESCE(substr(endsAt, 1, 10), substr(startsAt, 1, 10)) >= ?
     ORDER BY startsAt`,
  )
    .bind(me.userId, me.id, to, from)
    .all<EventRow>();

  return { status: 200, body: { events: results.map(eventJson) } };
}

export async function handleCreateEvent(env: Env, claims: AccessClaims, body: Record<string, unknown>): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const input = mergeEvent(body, null);

  if (!input) {
    return fail(400, 'invalid_request');
  }

  const count = await env.DB.prepare('SELECT COUNT(*) AS c FROM CalendarEvent WHERE userId = ?').bind(me.userId).first<{ c: number }>();

  if ((count?.c ?? 0) >= MAX_EVENTS) {
    return fail(409, 'too_many_events');
  }

  const id = crypto.randomUUID();
  const now = nowIso();

  await env.DB.prepare(
    `INSERT INTO CalendarEvent (id, userId, ownerProfileId, title, note, startsAt, endsAt, allDay, shared, createdAt, updatedAt)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(id, me.userId, me.id, input.title, input.note, input.startsAt, input.endsAt, input.allDay ? 1 : 0, input.shared ? 1 : 0, now, now)
    .run();

  return { status: 201, body: { id } };
}

async function visibleEvent(env: Env, me: Actor, id: string): Promise<EventRow | null> {
  return env.DB.prepare('SELECT * FROM CalendarEvent WHERE id = ? AND userId = ? AND (shared = 1 OR ownerProfileId = ?)')
    .bind(id, me.userId, me.id)
    .first<EventRow>();
}

export async function handleUpdateEvent(
  env: Env,
  claims: AccessClaims,
  id: string,
  body: Record<string, unknown>,
): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const current = await visibleEvent(env, me, id);

  if (!current) {
    return fail(404, 'not_found');
  }

  if (current.ownerProfileId !== me.id && me.role !== 'admin') {
    return fail(403, 'owner_required');
  }

  const input = mergeEvent(body, current);

  if (!input) {
    return fail(400, 'invalid_request');
  }

  await env.DB.prepare(
    `UPDATE CalendarEvent SET title = ?, note = ?, startsAt = ?, endsAt = ?, allDay = ?, shared = ?, updatedAt = ? WHERE id = ?`,
  )
    .bind(input.title, input.note, input.startsAt, input.endsAt, input.allDay ? 1 : 0, input.shared ? 1 : 0, nowIso(), id)
    .run();

  return { status: 200, body: { status: 'ok' } };
}

export async function handleDeleteEvent(env: Env, claims: AccessClaims, id: string): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const current = await visibleEvent(env, me, id);

  if (!current) {
    return fail(404, 'not_found');
  }

  if (current.ownerProfileId !== me.id && me.role !== 'admin') {
    return fail(403, 'owner_required');
  }

  await env.DB.prepare('DELETE FROM CalendarEvent WHERE id = ?').bind(id).run();

  return { status: 200, body: { status: 'ok' } };
}

// ---------------------------------------------------------------------------
// Wiadomosci miedzy profilami
// ---------------------------------------------------------------------------

const MAX_MESSAGE = 500;
const KEEP_DAYS = 60;

interface MessageRow {
  id: string;
  fromProfileId: string;
  toProfileId: string | null;
  body: string;
  createdAt: string;
  read: number;
}

export async function handleListMessages(env: Env, claims: AccessClaims): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const { results } = await env.DB.prepare(
    `SELECT m.id, m.fromProfileId, m.toProfileId, m.body, m.createdAt,
            CASE WHEN m.fromProfileId = ? OR r.messageId IS NOT NULL THEN 1 ELSE 0 END AS read
       FROM Message m
       LEFT JOIN MessageRead r ON r.messageId = m.id AND r.profileId = ?
      WHERE m.userId = ? AND (m.toProfileId = ? OR m.toProfileId IS NULL OR m.fromProfileId = ?)
      ORDER BY m.createdAt DESC LIMIT 200`,
  )
    .bind(me.id, me.id, me.userId, me.id, me.id)
    .all<MessageRow>();

  return {
    status: 200,
    body: {
      messages: results.map((m) => ({
        id: m.id,
        from: m.fromProfileId,
        to: m.toProfileId,
        body: m.body,
        createdAt: m.createdAt,
        read: m.read === 1,
      })),
      unread: results.filter((m) => m.read === 0).length,
    },
  };
}

export async function handleSendMessage(env: Env, claims: AccessClaims, body: Record<string, unknown>): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const message = text(body.body, MAX_MESSAGE);
  const to = body.to === undefined || body.to === null ? null : body.to;

  if (!message || (to !== null && typeof to !== 'string')) {
    return fail(400, 'invalid_request');
  }

  if (to !== null && (to === me.id || !(await profilesOfUser(env, me.userId, [to as string])))) {
    return fail(400, 'invalid_recipient');
  }

  const id = crypto.randomUUID();

  await env.DB.batch([
    env.DB.prepare(
      'INSERT INTO Message (id, userId, fromProfileId, toProfileId, body, createdAt) VALUES (?, ?, ?, ?, ?, ?)',
    ).bind(id, me.userId, me.id, to, message, nowIso()),
    // Wiadomosci nie sa archiwum: stare znikaja, zeby baza nie rosla bez konca.
    env.DB.prepare('DELETE FROM Message WHERE userId = ? AND createdAt < ?').bind(
      me.userId,
      new Date(Date.now() - KEEP_DAYS * 24 * 3600 * 1000).toISOString(),
    ),
  ]);

  const sender = await env.DB.prepare('SELECT name FROM Profile WHERE id = ?').bind(me.id).first<{ name: string }>();

  return {
    status: 201,
    body: { id },
    after: () =>
      pushToHousehold(env, me.userId, to as string | null, me.id, {
        title: sender?.name ?? 'NestIQ',
        body: message.length > 140 ? `${message.slice(0, 137)}...` : message,
        channel: 'messages',
        data: { type: 'message', id },
      }),
  };
}

/** Oznacza wiadomosci jako przeczytane: wskazane (`ids`) albo wszystkie (`all: true`). */
export async function handleMarkRead(env: Env, claims: AccessClaims, body: Record<string, unknown>): Promise<Result> {
  const me = await actor(env, claims);

  if (!me) {
    return NO_PROFILE();
  }

  const ids = body.ids;
  const all = body.all === true;

  if (!all && (!Array.isArray(ids) || ids.length === 0 || ids.length > 100 || !ids.every((v) => typeof v === 'string'))) {
    return fail(400, 'invalid_request');
  }

  const now = nowIso();
  const filter = all ? '' : ` AND m.id IN (${(ids as string[]).map(() => '?').join(',')})`;

  await env.DB.prepare(
    `INSERT OR IGNORE INTO MessageRead (messageId, profileId, readAt)
     SELECT m.id, ?, ? FROM Message m
      WHERE m.userId = ? AND m.fromProfileId != ? AND (m.toProfileId = ? OR m.toProfileId IS NULL)${filter}`,
  )
    .bind(me.id, now, me.userId, me.id, me.id, ...(all ? [] : (ids as string[])))
    .run();

  return { status: 200, body: { status: 'ok' } };
}
