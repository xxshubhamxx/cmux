import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

const getUser = mock(async () => ({
  id: "user-db-health",
  displayName: null,
  primaryEmail: "user@example.com",
}));

mock.module("../app/lib/stack", () => ({
  stackServerApp: { getUser },
}));

const { GET } = await import("../app/api/vm/db-health/route");

let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  sql = postgres(databaseURL, { max: 1 });
});

beforeEach(() => {
  getUser.mockClear();
  getUser.mockResolvedValue({
    id: "user-db-health",
    displayName: null,
    primaryEmail: "user@example.com",
  });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

describe("VM DB health route", () => {
  dbTest("requires authentication before opening the database", async () => {
    getUser.mockResolvedValue(null);

    const response = await GET(new Request("https://cmux.test/api/vm/db-health"));

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
  });

  dbTest("returns DB-backed VM and usage counts for the authenticated user", async () => {
    if (!sql) throw new Error("test database not initialized");

    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    const [runningVm] = await sql<{ id: string }[]>`
      insert into cloud_vms (
        user_id,
        provider,
        provider_vm_id,
        image_id,
        image_version,
        status,
        idempotency_key
      )
      values (
        'user-db-health',
        'e2b',
        'route-provider-vm-1',
        'cmuxd-ws:test',
        '2026-04-25.1',
        'running',
        'route-idem-1'
      )
      returning id
    `;
    await sql`
      insert into cloud_vms (user_id, provider, provider_vm_id, image_id, status, idempotency_key)
      values
        ('user-db-health', 'freestyle', 'route-provider-vm-2', 'sc-test', 'failed', 'route-idem-2'),
        ('other-user', 'e2b', 'route-provider-vm-other', 'cmuxd-ws:test', 'running', 'route-idem-other')
    `;
    await sql`
      insert into cloud_vm_usage_events (user_id, vm_id, event_type, provider, image_id, metadata)
      values
        (
          'user-db-health',
          ${runningVm.id},
          'vm.created',
          'e2b',
          'cmuxd-ws:test',
          '{"source":"route-test"}'::jsonb
        ),
        (
          'user-db-health',
          ${runningVm.id},
          'vm.attach',
          'e2b',
          'cmuxd-ws:test',
          '{"source":"route-test"}'::jsonb
        ),
        (
          'other-user',
          null,
          'vm.created',
          'e2b',
          'cmuxd-ws:test',
          '{"source":"route-test"}'::jsonb
        )
    `;

    const response = await GET(new Request("https://cmux.test/api/vm/db-health"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      cloudVms: {
        total: 2,
        byStatus: {
          failed: 1,
          running: 1,
        },
      },
      usageEvents: {
        total: 2,
      },
    });
  });
});
