import { actor } from "rivetkit";
import { getProvider, type ProviderId, type VMStatus } from "../drivers";
import { isProviderNotFoundError } from "../providerErrors";
import { requireActorAuth } from "../rivetSecurity";
import {
  recordSpanError,
  setSpanAttributes,
  withRivetActorSpan,
  type MaybeAttributes,
  type SpanCallback,
} from "../telemetry";

export type VMState = {
  provider: ProviderId;
  providerVmId: string; // also the actor key now — no cmux UUID layer.
  userId: string;       // Stack Auth user id, immutable after create.
  image: string;
  status: VMStatus;
  createdAt: number;
  pausedAt: number | null;
  /**
   * Identity handles returned by `openSSH`. Kept here (not thrown away after the endpoint is
   * handed out) so we can revoke them on VM destroy and before minting a fresh replacement.
   * Without this, every `cmux vm shell` call would leak a live Freestyle credential.
   */
  sshIdentityHandles: string[];
  snapshots: Array<{ id: string; name?: string; createdAt: number }>;
};

export type VMCreateInput = {
  provider: ProviderId;
  providerVmId: string;
  userId: string;
  image: string;
};

const VM_ACTION_TIMEOUT_MS = 16 * 60 * 1000;

// One actor per VM. Actor key is the provider's own id. The provider VM is already created by
// the caller (userVmsActor.create) before we spawn this actor — we just own lifecycle,
// per-VM actions (exec, snapshot, openSSH, remove, …), and cleanup of the credential material
// we mint on the user's behalf.
//
// Note on idle auto-pause: the previous design scheduled `autoPause` from `onDisconnect`, but
// `c.conns.size` tracks Rivet *actor* connections — not the SSH session the user actually
// cares about. Because our REST routes open stateless one-shot actor connections that close
// immediately, disconnect fired on every request and queued a 10-minute pause even while the
// user's SSH shell was wide open. That behavior is gone until we track real SSH session
// liveness (see the follow-up task for heartbeat wiring). Explicit `pause`/`resume` actions
// still work; we just don't fire them on our own schedule.
export const vmActor = actor({
  options: {
    name: "VM",
    icon: "cloud",
    actionTimeout: VM_ACTION_TIMEOUT_MS,
  },

  createState: (_c, input: VMCreateInput): VMState => ({
    provider: input.provider,
    providerVmId: input.providerVmId,
    userId: input.userId,
    image: input.image,
    status: "running",
    createdAt: Date.now(),
    pausedAt: null,
    sshIdentityHandles: [],
    snapshots: [],
  }),

  createConnState: (c, params: unknown) => {
    return requireActorAuth(params, c.state.userId);
  },

  onDestroy: async (c) => {
    await withVmActorSpan(
      c,
      "onDestroy",
      {
        "cmux.ssh.identity_count": c.state.sshIdentityHandles.length,
      },
      async (span) => {
        await revokeAllIdentities(c.state);
        if (c.state.status !== "destroyed" && c.state.providerVmId) {
          try {
            await getProvider(c.state.provider).destroy(c.state.providerVmId);
          } catch (err) {
            recordSpanError(span, err);
            // Best-effort; provider may have already evicted the VM.
          }
        }
      },
    );
  },

  actions: {
    pause: async (c) => {
      await withVmActorSpan(
        c,
        "pause",
        {},
        async (span) => {
          if (c.state.status === "paused") {
            setSpanAttributes(span, { "cmux.action.noop": true });
            return;
          }
          await getProvider(c.state.provider).pause(c.state.providerVmId);
          c.state.status = "paused";
          c.state.pausedAt = Date.now();
        },
      );
    },

    resume: async (c) => {
      await withVmActorSpan(
        c,
        "resume",
        {},
        async (span) => {
          if (c.state.status === "running") {
            setSpanAttributes(span, { "cmux.action.noop": true });
            return;
          }
          const handle = await getProvider(c.state.provider).resume(c.state.providerVmId);
          c.state.providerVmId = handle.providerVmId;
          c.state.status = "running";
          c.state.pausedAt = null;
          setSpanAttributes(span, { "cmux.vm.id": handle.providerVmId });
        },
      );
    },

    snapshot: async (c, name?: string) => {
      return withVmActorSpan(
        c,
        "snapshot",
        { "cmux.snapshot.named": !!name },
        async (span) => {
          const ref = await getProvider(c.state.provider).snapshot(c.state.providerVmId, name);
          c.state.snapshots.push({ id: ref.id, name: ref.name, createdAt: ref.createdAt });
          setSpanAttributes(span, { "cmux.snapshot.id": ref.id, "cmux.snapshot.count": c.state.snapshots.length });
          return ref;
        },
      );
    },

    exec: async (c, command: string, timeoutMs?: number) => {
      return withVmActorSpan(
        c,
        "exec",
        {
          "cmux.command_length": command.length,
          "cmux.timeout_ms": timeoutMs ?? 30_000,
        },
        async (span) => {
          const result = await getProvider(c.state.provider).exec(c.state.providerVmId, command, { timeoutMs });
          setSpanAttributes(span, { "cmux.exec.exit_code": result.exitCode });
          return result;
        },
      );
    },

    openSSH: async (c) => {
      return withVmActorSpan(
        c,
        "openSSH",
        { "cmux.ssh.identity_count": c.state.sshIdentityHandles.length },
        async (span) => {
          // Before minting a new identity, revoke any prior ones we've handed out for this VM.
          // `cmux vm shell` can be invoked repeatedly; without this step each call leaks a live
          // credential that outlives its usefulness.
          await revokeAllIdentities(c.state);
          c.state.sshIdentityHandles = [];
          const endpoint = await getProvider(c.state.provider).openSSH(c.state.providerVmId);
          if (endpoint.identityHandle) {
            c.state.sshIdentityHandles = [endpoint.identityHandle];
          }
          setSpanAttributes(span, {
            "cmux.ssh.identity_created": !!endpoint.identityHandle,
            "cmux.ssh.credential_kind": endpoint.credential.kind,
          });
          return endpoint;
        },
      );
    },

    openAttach: async (c, options?: { requireDaemon?: boolean }) => {
      const requireDaemon = options?.requireDaemon === true;
      return withVmActorSpan(
        c,
        "openAttach",
        {
          "cmux.ssh.identity_count": c.state.sshIdentityHandles.length,
          "cmux.vm.attach.require_daemon": requireDaemon,
        },
        async (span) => {
          await revokeAllIdentities(c.state);
          c.state.sshIdentityHandles = [];
          const endpoint = await getProvider(c.state.provider).openAttach(c.state.providerVmId, { requireDaemon });
          if (endpoint.transport === "ssh" && endpoint.identityHandle) {
            c.state.sshIdentityHandles = [endpoint.identityHandle];
          }
          setSpanAttributes(span, {
            "cmux.vm.attach.transport": endpoint.transport,
            "cmux.vm.attach.daemon_available": endpoint.transport === "websocket" && !!endpoint.daemon,
            "cmux.ssh.identity_created": endpoint.transport === "ssh" && !!endpoint.identityHandle,
            "cmux.ssh.credential_kind": endpoint.transport === "ssh" ? endpoint.credential.kind : "none",
          });
          return endpoint;
        },
      );
    },

    status: async (c) => {
      return withVmActorSpan(c, "status", {}, () => c.state);
    },

    remove: async (c) => {
      await withVmActorSpan(
        c,
        "remove",
        { "cmux.ssh.identity_count": c.state.sshIdentityHandles.length },
        async (span) => {
          await revokeAllIdentities(c.state);
          c.state.sshIdentityHandles = [];
          if (c.state.status !== "destroyed" && c.state.providerVmId) {
            // Surface provider destroy failures. Previously this path swallowed them, returned
            // success, and then the coordinator forget() dropped the last tracking reference —
            // the result was a ghost billable VM the user could no longer manage via cmux.
            // Rethrow so the REST layer returns 500 and the caller can retry. Codex P1.
            try {
              await getProvider(c.state.provider).destroy(c.state.providerVmId);
            } catch (err) {
              // Exception: if the provider says the VM is already gone (dashboard-deleted,
              // evicted for inactivity, etc.), treat that as success. Otherwise the user gets
              // stuck with a stale entry they can never remove via cmux because every retry
              // hits the same "not found". Codex P2.
              if (!isProviderNotFoundError(err)) throw err;
              setSpanAttributes(span, { "cmux.vm.provider_not_found": true });
            }
          }
          c.state.status = "destroyed";
          c.destroy();
        },
      );
    },
  },
});

function withVmActorSpan<T>(
  c: { state: VMState },
  actionName: string,
  attributes: MaybeAttributes,
  fn: SpanCallback<T>,
): Promise<T> {
  return withRivetActorSpan(
    "vmActor",
    actionName,
    {
      "cmux.vm.provider": c.state.provider,
      "cmux.vm.id": c.state.providerVmId,
      "cmux.vm.status": c.state.status,
      ...attributes,
    },
    fn,
  );
}

async function revokeAllIdentities(state: VMState): Promise<void> {
  if (state.sshIdentityHandles.length === 0) return;
  const provider = getProvider(state.provider);
  await Promise.all(
    state.sshIdentityHandles.map((handle) => provider.revokeSSHIdentity(handle)),
  );
}
