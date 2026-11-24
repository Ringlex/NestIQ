import {
  handleForgotPassword,
  handleLogin,
  handleRefresh,
  handleRegister,
  handleResendVerification,
  handleResetPassword,
  handleSignOut,
  handleVerifyEmail,
  verifyAccessToken,
  type AccessClaims,
} from './auth';
import type { Env } from './env';
import {
  handleCreateProfile,
  handleDeleteProfile,
  handleListProfiles,
  handleRecoverPin,
  handleSelectProfile,
  handleSetPin,
  handleUpdateProfile,
} from './profiles';
import {
  handleAddItem,
  handleClearChecked,
  handleCompleteReminder,
  handleCreateEvent,
  handleCreateList,
  handleCreateReminder,
  handleDeleteEvent,
  handleDeleteItem,
  handleDeleteList,
  handleDeleteReminder,
  handleListEvents,
  handleListLists,
  handleListMessages,
  handleListReminders,
  handleMarkRead,
  handleSendMessage,
  handleUpdateEvent,
  handleUpdateItem,
  handleUpdateList,
  handleUpdateReminder,
} from './household';
import { handleRegisterPush, handleUnregisterPush } from './push';
import { fail, json, type Result } from './util';

type PublicHandler = (env: Env, body: Record<string, unknown>) => Promise<Result>;

/** Trasy bez tokenu - to one dopiero wydaja tozsamosc. */
const PUBLIC_ROUTES: Record<string, PublicHandler> = {
  '/v1/auth/register': handleRegister,
  '/v1/auth/verify': handleVerifyEmail,
  '/v1/auth/resend': handleResendVerification,
  '/v1/auth/login': handleLogin,
  '/v1/auth/refresh': handleRefresh,
  '/v1/auth/sign-out': handleSignOut,
  '/v1/auth/password/forgot': handleForgotPassword,
  '/v1/auth/password/reset': handleResetPassword,
};

/** Zapytania sa male; wiekszy ladunek to pomylka albo naduzycie. */
const MAX_BODY_BYTES = 8 * 1024;

async function readBody(request: Request): Promise<Record<string, unknown> | null> {
  if (request.method === 'GET' || request.method === 'DELETE') {
    return {};
  }

  const text = await request.text();

  if (text.length > MAX_BODY_BYTES) {
    return null;
  }

  try {
    const parsed: unknown = text.length === 0 ? {} : JSON.parse(text);

    return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

async function authenticate(env: Env, request: Request): Promise<AccessClaims | null> {
  const header = request.headers.get('authorization') ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';

  return token ? verifyAccessToken(env, token) : null;
}

async function routeProtected(
  env: Env,
  claims: AccessClaims,
  method: string,
  path: string,
  body: Record<string, unknown>,
  query: URLSearchParams,
): Promise<Result> {
  const household = await routeHousehold(env, claims, method, path, body, query);

  if (household) {
    return household;
  }

  if (method === 'POST' && path === '/v1/push/register') return handleRegisterPush(env, claims, body);
  if (method === 'POST' && path === '/v1/push/unregister') return handleUnregisterPush(env, claims, body);

  if (path === '/v1/profiles') {
    if (method === 'GET') return handleListProfiles(env, claims);
    if (method === 'POST') return handleCreateProfile(env, claims, body);
  }

  const match = /^\/v1\/profiles\/([0-9a-f-]{36})(\/select|\/pin|\/pin\/recover)?$/.exec(path);

  if (match) {
    const id = match[1]!;

    switch (match[2]) {
      case undefined:
        if (method === 'PATCH') return handleUpdateProfile(env, claims, id, body);
        if (method === 'DELETE') return handleDeleteProfile(env, claims, id);
        break;
      case '/select':
        if (method === 'POST') return handleSelectProfile(env, claims, id, body);
        break;
      case '/pin':
        if (method === 'PUT') return handleSetPin(env, claims, id, body);
        break;
      case '/pin/recover':
        if (method === 'POST') return handleRecoverPin(env, claims, id, body);
        break;
    }
  }

  return fail(404, 'not_found');
}

const ID = '([0-9a-f-]{36})';

/** Planer domowy. `null` = to nie jest trasa planera. */
async function routeHousehold(
  env: Env,
  claims: AccessClaims,
  method: string,
  path: string,
  body: Record<string, unknown>,
  query: URLSearchParams,
): Promise<Result | null> {
  switch (`${method} ${path}`) {
    case 'GET /v1/lists':
      return handleListLists(env, claims);
    case 'POST /v1/lists':
      return handleCreateList(env, claims, body);
    case 'GET /v1/reminders':
      return handleListReminders(env, claims);
    case 'POST /v1/reminders':
      return handleCreateReminder(env, claims, body);
    case 'GET /v1/events':
      return handleListEvents(env, claims, query);
    case 'POST /v1/events':
      return handleCreateEvent(env, claims, body);
    case 'GET /v1/messages':
      return handleListMessages(env, claims);
    case 'POST /v1/messages':
      return handleSendMessage(env, claims, body);
    case 'POST /v1/messages/read':
      return handleMarkRead(env, claims, body);
  }

  let m = new RegExp(`^/v1/lists/${ID}$`).exec(path);
  if (m) {
    if (method === 'PATCH') return handleUpdateList(env, claims, m[1]!, body);
    if (method === 'DELETE') return handleDeleteList(env, claims, m[1]!);
  }

  m = new RegExp(`^/v1/lists/${ID}/items$`).exec(path);
  if (m && method === 'POST') return handleAddItem(env, claims, m[1]!, body);

  m = new RegExp(`^/v1/lists/${ID}/items/${ID}$`).exec(path);
  if (m) {
    if (method === 'PATCH') return handleUpdateItem(env, claims, m[1]!, m[2]!, body);
    if (method === 'DELETE') return handleDeleteItem(env, claims, m[1]!, m[2]!);
  }

  m = new RegExp(`^/v1/lists/${ID}/clear-checked$`).exec(path);
  if (m && method === 'POST') return handleClearChecked(env, claims, m[1]!);

  m = new RegExp(`^/v1/reminders/${ID}$`).exec(path);
  if (m) {
    if (method === 'PATCH') return handleUpdateReminder(env, claims, m[1]!, body);
    if (method === 'DELETE') return handleDeleteReminder(env, claims, m[1]!);
  }

  m = new RegExp(`^/v1/reminders/${ID}/done$`).exec(path);
  if (m && method === 'POST') return handleCompleteReminder(env, claims, m[1]!, body);

  m = new RegExp(`^/v1/events/${ID}$`).exec(path);
  if (m) {
    if (method === 'PATCH') return handleUpdateEvent(env, claims, m[1]!, body);
    if (method === 'DELETE') return handleDeleteEvent(env, claims, m[1]!);
  }

  return null;
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const { pathname } = new URL(request.url);

    if (pathname === '/health') {
      return json({ status: 'ok' }, 200);
    }

    const body = await readBody(request);

    if (!body) {
      return json({ error: 'invalid_request' }, 400);
    }

    const publicHandler = PUBLIC_ROUTES[pathname];

    if (publicHandler) {
      if (request.method !== 'POST') {
        return json({ error: 'method_not_allowed' }, 405);
      }

      const result = await publicHandler(env, body);

      return json(result.body, result.status);
    }

    const claims = await authenticate(env, request);

    if (!claims) {
      return json({ error: 'unauthorized' }, 401);
    }

    const result = await routeProtected(env, claims, request.method, pathname, body, new URL(request.url).searchParams);

    if (result.after) {
      ctx.waitUntil(result.after());
    }

    return json(result.body, result.status);
  },
};
