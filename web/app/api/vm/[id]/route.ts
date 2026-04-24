import {
  destroyTrackedProviderVm,
  isActorMissingError,
  jsonResponse,
  notFoundVm,
  userVmEntry,
  userVmsHandle,
  vmHandle,
  withAuthedVmApiRoute,
} from "../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../services/telemetry";

export const dynamic = "force-dynamic";

export async function DELETE(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]",
    { "cmux.vm.operation": "destroy" },
    "/api/vm/[id] DELETE failed",
    async ({ user, client, span }) => {
      const { id } = await params;
      setSpanAttributes(span, { "cmux.vm.id": id });
      // Prevent IDOR: a user may only destroy VMs tracked in their own coordinator actor.
      const tracked = await userVmEntry(client, user.id, id);
      if (!tracked) return notFoundVm(id);
      setSpanAttributes(span, { "cmux.vm.provider": tracked.provider });
      // `get` not `getOrCreate`: a coordinator entry without a live actor (partial cleanup
      // failure) should 404 instead of spawning an uninitialised actor that 500s. For the
      // DELETE path specifically we also forget() the coordinator entry regardless, so a
      // stale mapping can be cleaned up via retry.
      try {
        await vmHandle(client, user.id, id).remove();
      } catch (err) {
        // If the actor is genuinely missing, drop the coordinator reference so the user
        // isn't permanently stuck with an un-removable entry. This can happen when
        // userVmsActor.create provisioned the provider VM, vmActor.create failed, and the
        // rollback destroy also failed. Use the coordinator's preserved provider metadata to
        // retry direct provider cleanup before forget().
        if (isActorMissingError(err)) {
          setSpanAttributes(span, { "cmux.rivet.actor_missing": true });
          await destroyTrackedProviderVm(tracked);
        } else {
          throw err;
        }
      }
      await userVmsHandle(client, user.id).forget(id);
      return jsonResponse({ ok: true });
    },
  );
}
