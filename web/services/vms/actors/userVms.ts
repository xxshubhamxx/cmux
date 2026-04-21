import { actor } from "rivetkit";
import { defaultProviderId, getProvider, type ProviderId } from "../drivers";
import type { registry } from "../registry";

export type UserVmEntry = {
  providerVmId: string; // the provider's own id — also the vmActor actor key
  provider: ProviderId;
  image: string;
  createdAt: number;
  /**
   * Client-supplied idempotency key, stored so a retry with the same key returns the
   * existing VM instead of provisioning a second paid one. Undefined when the client
   * didn't pass a key (best-effort behaviour, older CLI/curl users).
   */
  idempotencyKey?: string;
};

export type UserVmsState = {
  vms: UserVmEntry[];
};

// One coordinator per Stack Auth user. Tracks `{providerVmId, provider, image}` for every VM
// this user owns. We use the provider's own id everywhere — no cmux UUID layer on top.
// Rationale: both Freestyle (`ob7ho8876hklod2xizof`) and E2B (`i453t8zwgbo38qqlmsgsl`) mint
// 20-char alphanumeric ids already; stacking a UUID on top just muddies CLI output and docs.
export const userVmsActor = actor({
  options: { name: "UserVMs", icon: "users" },

  state: { vms: [] } as UserVmsState,

  actions: {
    list: (c) => c.state.vms,

    create: async (
      c,
      opts: { image?: string; provider?: ProviderId; idempotencyKey?: string },
    ): Promise<UserVmEntry> => {
      // Idempotency: a client retry (network hiccup, timeout, bad Wi-Fi) previously got a
      // second paid provider VM for the same logical request. If the caller sent a key and
      // we already have a VM tracked under it for this user, return that entry unchanged —
      // the RivetKit runtime serializes actions per actor, so the second call is guaranteed
      // to see whatever state the first call committed.
      const idempotencyKey = opts.idempotencyKey?.trim();
      if (idempotencyKey) {
        const existing = c.state.vms.find((v) => v.idempotencyKey === idempotencyKey);
        if (existing) return existing;
      }
      const provider = opts.provider ?? defaultProviderId();
      // Provision the provider VM directly, then spawn a vmActor keyed on the provider id.
      // This avoids the vmActor.onCreate -> driver.create round trip (which used an extra
      // cmux-owned UUID) and means the actor key equals the provider id.
      const driver = getProvider(provider);
      const handle = await driver.create({ image: opts.image ?? "" });
      const entry: UserVmEntry = {
        providerVmId: handle.providerVmId,
        provider,
        image: handle.image,
        createdAt: handle.createdAt,
        idempotencyKey: idempotencyKey || undefined,
      };
      const client = c.client<typeof registry>();
      try {
        await client.vmActor.create([entry.providerVmId], {
          input: {
            userId: c.key[0] as string,
            provider,
            providerVmId: entry.providerVmId,
            image: entry.image,
          },
        });
      } catch (actorCreateError) {
        // vmActor.create failed *after* the provider already provisioned the VM. Without a
        // rollback, that VM lives on forever as an orphan (costing the user and cluttering
        // the Freestyle/E2B dashboard). Best-effort destroy + rethrow so the caller sees a
        // clean failure rather than a half-provisioned sandbox.
        try {
          await driver.destroy(entry.providerVmId);
        } catch {
          // The orphan-cleanup failure is less bad than the original; swallow but log.
          console.error(
            "userVmsActor.create: failed to roll back provider VM after vmActor.create error",
            { providerVmId: entry.providerVmId, provider },
          );
        }
        throw actorCreateError;
      }
      c.state.vms.push(entry);
      return entry;
    },

    forget: (c, providerVmId: string) => {
      c.state.vms = c.state.vms.filter((v) => v.providerVmId !== providerVmId);
    },
  },
});
