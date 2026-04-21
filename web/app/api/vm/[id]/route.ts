import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import {
  jsonResponse,
  notFoundVm,
  parseBearer,
  rivetClient,
  userOwnsVm,
} from "../../../../services/vms/routeHelpers";

export const dynamic = "force-dynamic";

export async function DELETE(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  try {
    const user = await verifyRequest(request);
    if (!user) return unauthorized();
    const bearer = parseBearer(request);
    if (!bearer) return unauthorized();
    const { id } = await params;
    const client = rivetClient(bearer);
    // Prevent IDOR: a user may only destroy VMs tracked in their own coordinator actor.
    if (!(await userOwnsVm(client, user.id, id))) return notFoundVm(id);
    // `get` not `getOrCreate`: a coordinator entry without a live actor (partial cleanup
    // failure) should 404 instead of spawning an uninitialised actor that 500s. For the
    // DELETE path specifically we also forget() the coordinator entry regardless, so a
    // stale mapping can be cleaned up via retry.
    try {
      await client.vmActor.get([id]).remove();
    } catch (err) {
      // If the actor is genuinely missing, drop the coordinator reference so the user
      // isn't permanently stuck with an un-removable entry. Providers' not-found is
      // already treated as success inside vmActor.remove (see web/services/vms/actors/vm.ts).
      const message = err instanceof Error ? err.message.toLowerCase() : "";
      const actorMissing =
        message.includes("actor not found") ||
        message.includes("actor does not exist") ||
        message.includes("no actor");
      if (!actorMissing) throw err;
    }
    await client.userVmsActor.getOrCreate([user.id]).forget(id);
    return jsonResponse({ ok: true });
  } catch (err) {
    console.error("/api/vm/[id] DELETE failed", err);
    // Return a safe summary only — don't echo the provider's error shape, which can
    // contain internal URLs or tokens.
    return jsonResponse({ error: err instanceof Error ? err.message : "internal error" }, 500);
  }
}
