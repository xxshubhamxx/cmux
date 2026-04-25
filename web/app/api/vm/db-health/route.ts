import { count, eq } from "drizzle-orm";
import { cloudDb } from "../../../../db/client";
import { cloudVms, cloudVmUsageEvents } from "../../../../db/schema";
import { recordSpanError, setSpanAttributes, withApiRouteSpan } from "../../../../services/telemetry";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

export const dynamic = "force-dynamic";

function countNumber(value: unknown): number {
  return typeof value === "number" ? value : Number(value ?? 0);
}

export async function GET(request: Request): Promise<Response> {
  return withApiRouteSpan(
    request,
    "/api/vm/db-health",
    {
      "cmux.subsystem": "vm-cloud",
      "cmux.vm.operation": "db_health",
    },
    async (span) => {
      try {
        const user = await verifyRequest(request);
        if (!user) return unauthorized();

        const db = cloudDb();
        const [{ total: vmTotal }] = await db
          .select({ total: count() })
          .from(cloudVms)
          .where(eq(cloudVms.userId, user.id));
        const vmStatusRows = await db
          .select({ status: cloudVms.status, total: count() })
          .from(cloudVms)
          .where(eq(cloudVms.userId, user.id))
          .groupBy(cloudVms.status);
        const [{ total: usageEventTotal }] = await db
          .select({ total: count() })
          .from(cloudVmUsageEvents)
          .where(eq(cloudVmUsageEvents.userId, user.id));

        const cloudVmTotal = countNumber(vmTotal);
        const usageEventsTotal = countNumber(usageEventTotal);
        const byStatus = Object.fromEntries(
          vmStatusRows.map((row) => [row.status, countNumber(row.total)]),
        );

        setSpanAttributes(span, {
          "cmux.vm.db.cloud_vms_total": cloudVmTotal,
          "cmux.vm.db.usage_events_total": usageEventsTotal,
        });

        return jsonResponse({
          ok: true,
          cloudVms: {
            total: cloudVmTotal,
            byStatus,
          },
          usageEvents: {
            total: usageEventsTotal,
          },
        });
      } catch (err) {
        recordSpanError(span, err);
        console.error("/api/vm/db-health GET failed", err);
        return jsonResponse({ error: "internal error" }, 500);
      }
    },
  );
}
