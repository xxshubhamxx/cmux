// Convenience REST facade over the VM actors. The authoritative path is `/api/rivet/*`; this
// route exists so curl + tests can exercise the service without speaking the full RivetKit
// protocol. Swift clients talk to /api/rivet/* directly and skip this file.

import { unauthorized, verifyRequest } from "../../../services/vms/auth";
import { defaultProviderId, type ProviderId } from "../../../services/vms/drivers";
import {
  jsonResponse,
  parseBearer,
  rivetClient,
} from "../../../services/vms/routeHelpers";

export const dynamic = "force-dynamic";

function errorResponse(message: string, status = 500): Response {
  return jsonResponse({ error: message }, status);
}

export async function GET(request: Request): Promise<Response> {
  try {
    const user = await verifyRequest(request);
    if (!user) return unauthorized();
    const bearer = parseBearer(request);
    if (!bearer) return unauthorized();
    const client = rivetClient(bearer);
    const entries = await client.userVmsActor.getOrCreate([user.id]).list();
    // REST adapter: expose `id` at the top level so existing CLI + curl users don't need to
    // learn the new `providerVmId` field name. Swift CLI reads `vm["id"]`.
    const vms = entries.map((entry) => ({
      id: entry.providerVmId,
      provider: entry.provider,
      image: entry.image,
      createdAt: entry.createdAt,
    }));
    return jsonResponse({ vms });
  } catch (err) {
    console.error("/api/vm GET failed", err);
    // Never return stack traces in REST responses — they leak server-internal paths and
    // sometimes credentials baked into error messages. Log the full error server-side;
    // send the client a safe summary only.
    return errorResponse(err instanceof Error ? err.message : "internal error");
  }
}

export async function POST(request: Request): Promise<Response> {
  try {
    const user = await verifyRequest(request);
    if (!user) return unauthorized();
    const bearer = parseBearer(request);
    if (!bearer) return unauthorized();

    // Runtime-validate the payload before we call a paid provider. An invalid `provider`
    // (client sending `"aws"` or `"docker"`) previously slipped past the type cast and
    // surfaced as a 500 from the driver after provisioning had already half-succeeded.
    let body: { image?: string; provider?: ProviderId };
    try {
      const raw = await request.json();
      // Reject non-objects AND arrays — `typeof [] === "object"` so the previous guard
      // silently accepted `[]` and treated it as `{}`, letting malformed clients still
      // provision a billable VM with defaults.
      if (raw !== null && (typeof raw !== "object" || Array.isArray(raw))) {
        throw new TypeError("body must be a JSON object");
      }
      const candidate = (raw ?? {}) as Record<string, unknown>;
      if (candidate.image !== undefined && typeof candidate.image !== "string") {
        return jsonResponse({ error: "`image` must be a string when provided" }, 400);
      }
      if (candidate.provider !== undefined) {
        if (typeof candidate.provider !== "string") {
          return jsonResponse({ error: "`provider` must be a string when provided" }, 400);
        }
        if (candidate.provider !== "e2b" && candidate.provider !== "freestyle") {
          return jsonResponse(
            { error: `provider must be "e2b" or "freestyle", got ${JSON.stringify(candidate.provider)}` },
            400,
          );
        }
      }
      body = {
        image: typeof candidate.image === "string" ? candidate.image : undefined,
        provider: candidate.provider as ProviderId | undefined,
      };
    } catch {
      return jsonResponse({ error: "invalid JSON body" }, 400);
    }
    const provider = body.provider ?? defaultProviderId();
    const image = body.image ?? defaultImageFor(provider);
    // Idempotency-Key is standard HTTP; we also accept x-cmux-idempotency-key for CLI
    // callers that don't know about RFC-style keys. Trim + clamp to a reasonable length
    // so we don't blow up actor state with garbage.
    const rawKey = (
      request.headers.get("idempotency-key") ||
      request.headers.get("x-cmux-idempotency-key") ||
      ""
    ).trim();
    const idempotencyKey = rawKey ? rawKey.slice(0, 128) : undefined;

    const client = rivetClient(bearer);
    const created = await client.userVmsActor.getOrCreate([user.id]).create({ image, provider, idempotencyKey });
    return jsonResponse({
      id: created.providerVmId,
      provider: created.provider,
      image: created.image,
      createdAt: created.createdAt,
    });
  } catch (err) {
    console.error("/api/vm POST failed", err);
    // Never return stack traces in REST responses — they leak server-internal paths and
    // sometimes credentials baked into error messages. Log the full error server-side;
    // send the client a safe summary only.
    return errorResponse(err instanceof Error ? err.message : "internal error");
  }
}

function defaultImageFor(provider: ProviderId): string {
  if (provider === "e2b") {
    return process.env.E2B_SANDBOX_TEMPLATE ?? "cmux-sandbox:v0-71a954b8e53b";
  }
  // Freestyle default populated when its snapshot lands.
  return process.env.FREESTYLE_SANDBOX_SNAPSHOT ?? "";
}
