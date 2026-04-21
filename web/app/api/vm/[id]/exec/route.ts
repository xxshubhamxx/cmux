import { unauthorized, verifyRequest } from "../../../../../services/vms/auth";
import {
  jsonResponse,
  notFoundVm,
  parseBearer,
  rivetClient,
  userOwnsVm,
} from "../../../../../services/vms/routeHelpers";

export const dynamic = "force-dynamic";

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  try {
    const user = await verifyRequest(request);
    if (!user) return unauthorized();
    const bearer = parseBearer(request);
    if (!bearer) return unauthorized();

    let rawBody: unknown;
    try {
      rawBody = await request.json();
    } catch {
      return jsonResponse({ error: "invalid JSON body" }, 400);
    }
    if (rawBody === null || typeof rawBody !== "object") {
      return jsonResponse({ error: "body must be a JSON object" }, 400);
    }
    const body = rawBody as { command?: unknown; timeoutMs?: unknown };
    if (typeof body.command !== "string" || body.command.length === 0) {
      return jsonResponse({ error: "`command` is required and must be a non-empty string" }, 400);
    }
    // Clamp the timeout so a client can't tie up provider quota on a runaway exec. Upper
    // bound matches the provider defaults (15 min on Freestyle); negative / non-number
    // values fall back to 30s.
    const MAX_EXEC_TIMEOUT_MS = 15 * 60 * 1000;
    const rawTimeout = body.timeoutMs;
    const timeoutMs = typeof rawTimeout === "number" && Number.isFinite(rawTimeout) && rawTimeout > 0
      ? Math.min(Math.floor(rawTimeout), MAX_EXEC_TIMEOUT_MS)
      : 30_000;

    const { id } = await params;
    const client = rivetClient(bearer);
    if (!(await userOwnsVm(client, user.id, id))) return notFoundVm(id);
    // `get` (not `getOrCreate`) so a coordinator entry without a live actor — e.g. after
    // a partial cleanup failure where userVmsActor kept the id but vmActor.state is gone —
    // 404s instead of implicit-creating an uninitialised actor that 500s on every action
    // (Codex P2).
    const result = await client.vmActor
      .get([id])
      .exec(body.command, timeoutMs);
    return jsonResponse(result);
  } catch (err) {
    console.error("/api/vm/[id]/exec POST failed", err);
    return jsonResponse({ error: err instanceof Error ? err.message : "internal error" }, 500);
  }
}
