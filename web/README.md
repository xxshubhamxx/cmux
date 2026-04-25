# cmux web

Next.js app deployed as the existing Vercel `manaflow/cmux` project. The app serves the website,
Stack Auth handlers, feedback endpoint, and Cloud VM backend routes.

## Development

```bash
bun install
bun dev
```

`bun dev` listens on `CMUX_PORT` when it is set, otherwise `PORT`, otherwise `3777`.

## Local Postgres

Local Postgres is isolated per worktree by deriving its port and Docker names from `CMUX_PORT` and
the git branch.

```bash
CMUX_PORT=10180 bun db:up
CMUX_PORT=10180 bun db:migrate
CMUX_PORT=10180 bun db:status
```

With `CMUX_PORT=10180`, Postgres listens on `localhost:20180`. A second worktree with
`CMUX_PORT=10181` listens on `localhost:20181`, so multiple dev environments can run on one
machine.

Useful commands:

```bash
bun db:up       # start this worktree's Postgres
bun db:migrate  # apply Drizzle migrations
bun db:test     # start an isolated test DB on CMUX_PORT+11000 and run DB behavior tests
bun db:status   # print container, volume, port, and redacted DATABASE_URL
bun db:reset    # delete and recreate this worktree's DB volume
bun db:down     # stop this worktree's DB
```

The local default URL shape is:

```text
postgres://cmux:cmux@localhost:${CMUX_PORT + 10000}/cmux
```

## Database

Schema lives in `db/schema.ts`. SQL migrations live in `db/migrations`.

Generate a migration after schema edits:

```bash
bunx drizzle-kit generate --config drizzle.config.ts
```

Apply migrations:

```bash
bun db:migrate
```

CI applies migrations twice against a real Postgres service and runs `tests/db-schema.test.ts` to
verify the runtime behavior we rely on, including per-user create idempotency.
