import { registry } from "../../../../services/vms/registry";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import {
  assertRivetInternal,
  requireRivetPrivateEndpointForPublicStart,
} from "../../../../services/vms/rivetSecurity";
import { setSpanAttributes, withApiRouteSpan } from "../../../../services/telemetry";

export const dynamic = "force-dynamic";

type RouteContext = { params: Promise<{ path?: string[] }> };

async function handle(request: Request, context: RouteContext): Promise<Response> {
  return withApiRouteSpan(
    request,
    "/api/rivet/[...path]",
    { "cmux.runtime": "rivetkit", "cmux.rivet.gateway": true },
    async (span) => {
      const path = (await context.params).path ?? [];
      if (request.method === "GET" && path.length === 1 && path[0] === "start") {
        requireRivetPrivateEndpointForPublicStart();
        setSpanAttributes(span, { "cmux.rivet.public_start": true });
        return registry.handler(request);
      }

      // `/api/rivet/*` is the raw RivetKit protocol surface. Actor keys are client-chosen, so a
      // plain "is this user authenticated" check is not enough: a signed-in user could point a
      // raw Rivet client here and target another user's actor by keying with their id. Gate on
      // a shared secret so only our own REST routes — which do user + ownership checks first —
      // can reach actors. External callers cannot forge the secret.
      if (!assertRivetInternal(request)) return unauthorized();
      const user = await verifyRequest(request);
      if (!user) return unauthorized();
      setSpanAttributes(span, { "cmux.authenticated": true });
      // Strip any client-supplied `x-cmux-user-id` header before asserting our own. Appending
      // via the array spread left a pre-existing client value readable first by any code that
      // naively took the first match — letting a forged header smuggle a different identity
      // through. Use Headers.set to guarantee the value we write is authoritative.
      const patchedHeaders = new Headers(request.headers);
      patchedHeaders.delete("x-cmux-user-id");
      patchedHeaders.set("x-cmux-user-id", user.id);
      const patched = new Request(request, { headers: patchedHeaders });
      return registry.handler(patched);
    },
  );
}

export const GET = handle;
export const POST = handle;
export const PUT = handle;
export const DELETE = handle;
export const PATCH = handle;
