import type { Span } from "@opentelemetry/api";
import { createClient, type Client } from "rivetkit/client";
import { recordSpanError, withApiRouteSpan, type MaybeAttributes } from "../telemetry";
import { unauthorized, verifyRequest, type AuthedUser } from "./auth";
import { getProvider } from "./drivers";
import { isProviderNotFoundError } from "./providerErrors";
import type { UserVmEntry } from "./actors/userVms";
import type { Registry } from "./registry";
import {
  RIVET_INTERNAL_HEADER,
  makeActorAuthParams,
  rivetInternalSecret,
} from "./rivetSecurity";

/** Bearer + refresh token pair the mac app stashes in keychain. */
export type StackBearer = { accessToken: string; refreshToken: string };

/**
 * Gate for `/api/rivet/*`. REST routes authenticate and do ownership checks before
 * forwarding actor calls with this server-only header and signed actor params.
 */

/**
 * Authoritative base URL for the Rivet gateway. Explicit non-loopback
 * `CMUX_VM_API_BASE_URL` values win, and Vercel previews use `VERCEL_URL`. Local dev prefers
 * the active cmux-assigned port so stale `.env.local` values like `localhost:9910` don't send
 * RivetKit metadata fetches to a dead process. Deriving this from `request.url.origin` is unsafe
 * because a misconfigured reverse proxy could rewrite Host and redirect Stack Auth tokens to an
 * attacker-controlled endpoint.
 */
function validPort(value: string | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed && /^\d+$/.test(trimmed) ? trimmed : null;
}

function activeLocalOriginFromEnv(): { origin: string; port: string } | null {
  const port = validPort(process.env.CMUX_PORT) ?? validPort(process.env.PORT);
  return port ? { origin: `http://localhost:${port}`, port } : null;
}

function loopbackURLPort(value: string): string | null {
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    const isLoopback =
      host === "localhost" || host === "127.0.0.1" || host === "0.0.0.0" || host === "::1";
    if (!isLoopback) return null;
    if (url.port) return url.port;
    if (url.protocol === "https:") return "443";
    if (url.protocol === "http:") return "80";
    return null;
  } catch {
    return null;
  }
}

function rivetBaseURL(): string {
  const explicit = process.env.CMUX_VM_API_BASE_URL?.trim();
  const local = activeLocalOriginFromEnv();
  if (explicit) {
    const normalized = explicit.replace(/\/$/, "");
    const explicitLoopbackPort = loopbackURLPort(normalized);
    if (
      process.env.NODE_ENV !== "production" &&
      local &&
      explicitLoopbackPort &&
      explicitLoopbackPort !== local.port
    ) {
      return local.origin;
    }
    return normalized;
  }
  const vercel = process.env.VERCEL_URL?.trim();
  if (vercel) return `https://${vercel}`;
  return local?.origin ?? "http://localhost:3777";
}

function rivetInternalClientEndpoint(): string {
  const base = rivetBaseURL();
  try {
    const url = new URL(base);
    const host = url.hostname.toLowerCase();
    if (host === "localhost" || host === "0.0.0.0" || host === "::1") {
      url.hostname = "127.0.0.1";
    }
    url.pathname = `${url.pathname.replace(/\/$/, "")}/api/rivet`;
    return url.toString().replace(/\/$/, "");
  } catch {
    return `${base}/api/rivet`;
  }
}

export function parseBearer(request: Request): StackBearer | null {
  const auth = request.headers.get("authorization");
  const refresh = request.headers.get("x-stack-refresh-token");
  if (!auth?.toLowerCase().startsWith("bearer ") || !refresh) return null;
  const accessToken = auth.slice("bearer ".length).trim();
  const refreshToken = refresh.trim();
  if (!accessToken || !refreshToken) return null;
  return { accessToken, refreshToken };
}

/**
 * Credentials to forward to the Rivet catch-all. Bearer is the mac app's path (Stack
 * access + refresh tokens); cookie is the browser path (Stack session cookies the Next
 * middleware already set). Forward both when both are present so `/api/rivet/*` preserves
 * `verifyRequest`'s bearer-then-cookie fallback behavior.
 */
export type ForwardedCreds = {
  bearer?: StackBearer;
  cookie?: string;
};

export function parseForwardedCreds(request: Request): ForwardedCreds | null {
  const bearer = parseBearer(request);
  const cookie = request.headers.get("cookie");
  const trimmedCookie = cookie?.trim();
  const creds: ForwardedCreds = {};
  if (bearer) creds.bearer = bearer;
  if (trimmedCookie) creds.cookie = trimmedCookie;
  return creds.bearer || creds.cookie ? creds : null;
}

export function rivetClient(creds: ForwardedCreds): Client<Registry> {
  const headers: Record<string, string> = {
    [RIVET_INTERNAL_HEADER]: rivetInternalSecret(),
  };
  if (creds.bearer) {
    headers.authorization = `Bearer ${creds.bearer.accessToken}`;
    headers["x-stack-refresh-token"] = creds.bearer.refreshToken;
  }
  if (creds.cookie) {
    headers.cookie = creds.cookie;
  }
  // RivetKit needs metadata lookup in local dev so `/api/rivet/metadata` can point the
  // client at the spawned local manager that serves `/actors`. Prefer 127.0.0.1 for the
  // server-side client so it does not reuse a stale localhost metadata retry cache.
  const endpoint = rivetInternalClientEndpoint();
  return createClient<Registry>({
    endpoint,
    headers,
  });
}

export type AuthedVmRouteContext = {
  user: AuthedUser;
  creds: ForwardedCreds;
  client: Client<Registry>;
  span: Span;
};

export function userVmsHandle(client: Client<Registry>, userId: string) {
  return client.userVmsActor.getOrCreate([userId], { params: makeActorAuthParams(userId) });
}

export function vmHandle(client: Client<Registry>, userId: string, vmId: string) {
  return client.vmActor.get([vmId], { params: makeActorAuthParams(userId) });
}

export async function withAuthedVmApiRoute(
  request: Request,
  route: string,
  attributes: MaybeAttributes,
  failureLog: string,
  handler: (context: AuthedVmRouteContext) => Promise<Response>,
): Promise<Response> {
  return withApiRouteSpan(
    request,
    route,
    { "cmux.subsystem": "vm-cloud", ...attributes },
    async (span) => {
      try {
        const user = await verifyRequest(request);
        if (!user) return unauthorized();
        const creds = parseForwardedCreds(request);
        if (!creds) return unauthorized();
        return await handler({ user, creds, client: rivetClient(creds), span });
      } catch (err) {
        recordSpanError(span, err);
        console.error(failureLog, err);
        return jsonResponse({ error: err instanceof Error ? err.message : "internal error" }, 500);
      }
    },
  );
}

/**
 * Confirms this user owns `vmId` before any mutation (destroy, exec, openSSH, snapshot).
 * Prevents IDOR: without this, any authenticated user could DELETE/exec/ssh anyone else's
 * VM by passing the raw provider id to the route. Checks against the coordinator actor's
 * own list rather than asking the vmActor directly (the vmActor would happily getOrCreate a
 * brand-new shell actor for an id it's never seen).
 */
export async function userOwnsVm(
  client: Client<Registry>,
  userId: string,
  vmId: string,
): Promise<boolean> {
  return (await userVmEntry(client, userId, vmId)) !== null;
}

export async function userVmEntry(
  client: Client<Registry>,
  userId: string,
  vmId: string,
): Promise<UserVmEntry | null> {
  const list = await userVmsHandle(client, userId).list();
  return list.find((v) => v.providerVmId === vmId) ?? null;
}

export async function destroyTrackedProviderVm(entry: UserVmEntry): Promise<void> {
  try {
    await getProvider(entry.provider).destroy(entry.providerVmId);
  } catch (err) {
    if (!isProviderNotFoundError(err)) throw err;
  }
}

/**
 * `Response.json(...)` misbehaves under Next.js 16's turbopack dev build (the handler's
 * promise settles but turbopack reports "No response is returned from route handler").
 * Use `new Response(JSON.stringify(...), { ... })` explicitly instead.
 */
export function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function notFoundVm(vmId: string): Response {
  return jsonResponse({ error: `vm not found: ${vmId}` }, 404);
}

/**
 * True when an error thrown by a `vmActor.get([id]).<action>()` call looks like the actor
 * key doesn't resolve to a live actor — i.e. the coordinator still lists the id but its
 * vmActor state is gone (partial cleanup, etc.). Routes use this to map stale entries to
 * a 404 instead of bubbling as an opaque 500.
 */
export function isActorMissingError(err: unknown): boolean {
  const message = err instanceof Error ? err.message.toLowerCase() : "";
  if (!message) return false;
  return (
    message.includes("actor not found") ||
    message.includes("actor does not exist") ||
    message.includes("no actor") ||
    message.includes("actor is not available")
  );
}
