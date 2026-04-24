import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { UserError } from "rivetkit";

export const RIVET_INTERNAL_HEADER = "x-cmux-rivet-internal";

export type ActorAuthParams = {
  userId: string;
  sig: string;
};

const globalForRivetSecret = globalThis as typeof globalThis & {
  __cmuxRivetInternalSecret?: string;
};

/**
 * Process-local fallback secret. Local dev route handlers can be compiled as separate
 * Turbopack bundles, so a module-level constant is not enough. Store the fallback on
 * globalThis so `/api/vm` and `/api/rivet` agree inside the same Next dev process.
 */
function devFallbackSecret(): string {
  if (!globalForRivetSecret.__cmuxRivetInternalSecret) {
    globalForRivetSecret.__cmuxRivetInternalSecret = `cmux-dev-${randomBytes(24).toString("hex")}`;
  }
  return globalForRivetSecret.__cmuxRivetInternalSecret;
}

function looksDeployed(): boolean {
  return (
    process.env.NODE_ENV === "production" ||
    process.env.NODE_ENV === "test" ||
    !!process.env.VERCEL ||
    !!process.env.VERCEL_URL ||
    !!process.env.VERCEL_ENV ||
    !!process.env.CMUX_DEPLOY_ENV
  );
}

/**
 * Read the internal secret lazily so tests can override via process.env before this module
 * is loaded. In production we require the caller to set it explicitly so we don't degrade
 * into "any authenticated request is trusted".
 */
export function rivetInternalSecret(): string {
  const value = process.env.CMUX_RIVET_INTERNAL_SECRET?.trim();
  if (value) return value;
  if (looksDeployed()) {
    throw new Error(
      "CMUX_RIVET_INTERNAL_SECRET must be set in any deployed environment, " +
        "the per-process dev fallback is incompatible with multi-worker setups.",
    );
  }
  return devFallbackSecret();
}

export function assertRivetInternal(request: Request): boolean {
  const header = request.headers.get(RIVET_INTERNAL_HEADER);
  if (!header) return false;
  return constantTimeEqual(header, rivetInternalSecret());
}

export function makeActorAuthParams(userId: string): ActorAuthParams {
  const normalizedUserId = userId.trim();
  return {
    userId: normalizedUserId,
    sig: signActorUser(normalizedUserId),
  };
}

export function requireActorAuth(params: unknown, expectedUserId: string): ActorAuthParams {
  if (!isActorAuthParams(params)) {
    throw new UserError("Unauthorized", { code: "unauthorized" });
  }
  if (params.userId !== expectedUserId || !constantTimeEqual(params.sig, signActorUser(params.userId))) {
    throw new UserError("Unauthorized", { code: "unauthorized" });
  }
  return params;
}

export function rivetPrivateEndpointConfigured(): boolean {
  return !!(
    process.env.RIVET_ENDPOINT?.trim() ||
    (process.env.RIVET_TOKEN?.trim() && process.env.RIVET_NAMESPACE?.trim())
  );
}

export function requireRivetPrivateEndpointForPublicStart(): void {
  if (!looksDeployed() || rivetPrivateEndpointConfigured()) return;
  throw new Error(
    "RIVET_ENDPOINT or RIVET_TOKEN/RIVET_NAMESPACE must be set before exposing /api/rivet/start.",
  );
}

function signActorUser(userId: string): string {
  return createHmac("sha256", rivetInternalSecret())
    .update("cmux-rivet-actor-auth:v1")
    .update("\0")
    .update(userId)
    .digest("hex");
}

function isActorAuthParams(value: unknown): value is ActorAuthParams {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Record<string, unknown>;
  return typeof candidate.userId === "string" && typeof candidate.sig === "string";
}

function constantTimeEqual(a: string, b: string): boolean {
  const aBuffer = Buffer.from(a);
  const bBuffer = Buffer.from(b);
  if (aBuffer.length !== bBuffer.length) return false;
  return timingSafeEqual(aBuffer, bBuffer);
}
