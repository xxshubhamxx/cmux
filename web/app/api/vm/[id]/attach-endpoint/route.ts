import {
  isActorMissingError,
  jsonResponse,
  notFoundVm,
  userOwnsVm,
  vmHandle,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";

export const dynamic = "force-dynamic";

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/attach-endpoint",
    { "cmux.vm.operation": "open_attach" },
    "/api/vm/[id]/attach-endpoint failed",
    async ({ user, client, span }) => {
      const { id } = await params;
      const body = await parseAttachBody(request);
      const requireDaemon = body.requireDaemon === true || body.require_daemon === true;
      setSpanAttributes(span, { "cmux.vm.id": id });
      setSpanAttributes(span, { "cmux.vm.attach.require_daemon": requireDaemon });
      if (!(await userOwnsVm(client, user.id, id))) return notFoundVm(id);
      try {
        const endpoint = await vmHandle(client, user.id, id).openAttach({ requireDaemon });
        setSpanAttributes(span, { "cmux.vm.attach.transport": endpoint.transport });
        return jsonResponse(endpoint);
      } catch (err) {
        if (isActorMissingError(err)) {
          setSpanAttributes(span, { "cmux.rivet.actor_missing": true });
          return notFoundVm(id);
        }
        throw err;
      }
    },
  );
}

async function parseAttachBody(request: Request): Promise<Record<string, unknown>> {
  try {
    const body = await request.json();
    return body && typeof body === "object" && !Array.isArray(body)
      ? body as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}
