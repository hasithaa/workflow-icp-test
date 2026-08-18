# workflow-icp-test

A local Docker environment for the ICP × Ballerina Workflow work: **two clusters that cannot
reach each other**, an **ICP that can be run as a cluster**, **two workflow integrations with
multiple nodes each**, and a **real Postgres initialised from the ICP's own SQL scripts**.

It exists to test the three things the H2/single-process test setup could not:

| | |
|---|---|
| **The SQL scripts** | Postgres, initialised from `postgresql_init.sql`, plus a fresh-vs-migrated comparison of `add_workflow_feature_postgresql.sql` |
| **Cross-cluster operation** | The ICP has no network route to any integration. Everything works or nothing does |
| **Multi-node** | Several workers per integration on one Temporal task queue, and optionally two ICP nodes |
| **A real Temporal** | The open-source server on Postgres — SQL visibility, so the human-task views work; no dev-server caveats |

```
                icp-net                    │  edge  │            integration-net
  ┌──────────┐  ┌───────┐  ┌───────┐       │ (nginx │   ┌─────────┐ ┌────────┐ ┌──────────┐
  │ postgres │  │ icp-1 │  │ icp-2 │◄──────┤  L4    ├──►│ expense │ │ orders │ │ temporal │
  └──────────┘  └───────┘  └───────┘       │ proxy) │   │   ×N    │ │   ×N   │ │  + its   │
                                           └────────┘   └─────────┘ └────────┘ │ postgres │
                                                                               └──────────┘
                     ▲                                        │
                     └──── no route this way ─────────────────┘
```

`edge` is the only container on both networks, and it is a plain TCP proxy. An integration can
reach the ICP; the ICP cannot reach an integration. That is the property under test.

---

## Prerequisites

- Docker with **8 GB** available for the cluster profile (~4 GB for the default one). Measured
  idle on the default profile: ICP ~590 MB, each integration ~390 MB, Temporal ~90 MB, its
  Postgres ~130 MB, the ICP's Postgres ~75 MB.
- Local checkouts of the three repos, on the branches under test:
  `integration-control-plane`, `module-ballerina-workflow`, `icp-runtime-bridge`.
- Ballerina **2201.13.4** on the host (integrations are built there, not in Docker — they need
  the local bala repository).
- The bridge builds as a connector, so its own build needs Docker too.

## Run it

```bash
# 1. Build everything from your branches and stage it into the build contexts.
#    Override SRC_ROOT if your checkouts are not in ~/Source/workflow/ICP_REWAMP.
SRC_ROOT=~/Source/workflow/ICP_REWAMP ./scripts/build-artifacts.sh

# 2. Bring up the control plane, mint the org secrets, start the integrations.
./scripts/bootstrap.sh            # or: ./scripts/bootstrap.sh --cluster

# 3. Give the console user the roles the human tasks are addressed to (see Findings).
./scripts/grant-task-roles.sh     # APPROVER, OPS

# 4. Drive the workflow features and assert the outcomes.
./scripts/smoke.sh                # add --include-offline for the 503 check

# 5. Test the SQL scripts (fresh install vs migrated, on the running Postgres).
./scripts/db-scripts-test.sh
```

Console: <https://localhost:9446> (`admin` / `admin`, self-signed certificate).
Temporal UI: `docker compose --profile ui up -d temporal-ui`, then <http://localhost:8233>. Postgres: `localhost:55432` (`postgres`/`postgres`).

Tear down with `docker compose down -v` (the `-v` matters: the Postgres volume holds the
initialised schema, so keeping it skips the init scripts next time).

---

## What each script proves

### `scripts/db-scripts-test.sh` — the SQL scripts

Runs both supported paths against the live Postgres and compares the results:

- **fresh** — `postgresql_init.sql` on an empty database;
- **upgrade** — a pre-workflow database (built by initialising fresh and then dropping
  `bi_workflow_metadata`, `runtimes.callback_url` and the `workflow_mgt:*` permissions), then
  `add_workflow_feature_postgresql.sql`, applied **twice** to check idempotency.

It then asserts the migrated database matches the fresh one on the table's columns, primary
key and foreign key, the `callback_url` column, the four permissions, the permission domain
and all sixteen role grants — and finally that `DELETE FROM bi_workflow_metadata` succeeds,
because heartbeat processing runs that statement unconditionally. A missing table there fails
*every* full heartbeat, MI runtimes included.

### `scripts/smoke.sh` — the workflow features across the boundary

22 assertions, all through the ICP's own HTTP API:

- both integrations registered, each with the expected number of RUNNING runtimes;
- both promoted to `ballerinaWorkflow` on their first full heartbeat (the auto-registration
  fix — a component auto-created from a heartbeat otherwise stays `service` and shows no
  Workflows view);
- every runtime published its descriptor and advertises `workflowCommands`;
- definitions listed per integration, **from stored metadata** — no request into the runtime;
- `expenseApproval` starts through the tunnel (HTTP 201), reaches RUNNING, its human task is
  listed, is **completed through the tunnel**, and the workflow then reaches COMPLETED;
- `orderFulfilment` starts and accepts suspend, resume and terminate while parked on an event;
- with `--include-offline`: a stopped integration's instance views answer **503** while
  definitions still answer 200, because those come from the database.

---

## The two integrations

Different on purpose, so between them they cover the whole management surface.

| | `expense` | `orders` |
|---|---|---|
| Task queue | `EXPENSE_TASK_QUEUE` | `ORDERS_TASK_QUEUE` |
| Workflows | `expenseApproval` (human task), `expenseAudit` (plain) | `orderFulfilment` (event wait), `orderReconciliation` (review activity), `bulkOrderIntake` (child workflows) |
| Exercises | human tasks, activities | lifecycle on a genuinely running instance, review activities, parent/child instance views |

Both import the bridge and nothing else: no management port, no workflow-specific plumbing.
Each replica is another worker on the same task queue, so the ICP sees one integration with N
runtimes — which is what makes definition dedup, `workerCount` and target selection
observable.

---

## Clustering the ICP, and the limitation it exposes

`./scripts/bootstrap.sh --cluster` runs two ICP nodes against one Postgres, with two replicas
of each integration.

**The command tunnel is single-instance today.** Its queue, waiters and results live in memory
on the node that accepted the console request, so a result posted to a *different* node has
nobody waiting for it and the caller times out with 504 after 25s. `edge/nginx.pinned.conf`
(the default) therefore sends all workflow traffic to `icp-1`.

To observe the limitation rather than work around it:

```bash
EDGE_CONF=nginx.roundrobin.conf docker compose --profile cluster up -d edge
./scripts/smoke.sh     # expect intermittent 504s on the tunnel calls
```

Definitions keep working throughout, because they are served from the database. That contrast
is the useful part: it shows exactly where the boundary between "clustered" and "not yet" sits,
and it is the evidence for whichever fix is chosen — shared state for the queue, or routing
workflow traffic by runtime.

---

## Findings from building this

Things the environment surfaced that are worth knowing before you use it:

- **An org secret binds to the first project/component that presents it.** Two integrations
  sharing one secret is not a configuration shortcut: the second is rejected with `Key ID … is
  already bound to a different project/component` and registers no runtime at all.
  `bootstrap.sh` therefore mints one secret per integration.
- **Postgres needs the credentials schema too.** `postgresql_init.sql` does not create
  `user_credentials` — `credentials_postgresql_init.sql` does, and it seeds `admin`. Without it
  the server starts, then every login fails with `Authentication service error` and
  `relation "user_credentials" does not exist`. The credentials client sets no schema, so the
  tables must be on the default `search_path` of the database named by `credentialsDbName`;
  this environment gives them their own `credentials_db`. Note the shipped
  `deployment.toml` comment says credentials live "in a `credentials` schema within the same
  database", which does not match what the code does.
- **Empty human-task views are usually role gating, not a bug.** `awaitHumanTask(…, "APPROVER")`
  is visible only to a caller holding APPROVER, and the ICP passes the *console user's* roles
  into the tunnel. The seeded admin holds `Super Admin` and `Project Admin`, so the views are
  correctly empty until the role exists and is granted — `scripts/grant-task-roles.sh` does
  that (there is no GraphQL mutation for creating roles, so it seeds them). With APPROVER
  granted, the listing returns the task with `canComplete: true` and completion drives the
  workflow to COMPLETED. This was originally misdiagnosed here as a Temporal dev-server
  limitation; it is not — the same emptiness occurs on the open-source server.
- **Size the ICP connection pool above the concurrent heartbeat load.** With
  `maxOpenConnections = 8`, two integrations plus the scheduler jobs were enough to leave a
  heartbeat transaction `idle in transaction` while other heartbeats queued on its `runtimes`
  row lock; the pool then timed out after 30s and the bridge reported
  `Idle timeout triggered before initiating inbound response`. Nothing recovers on its own
  until the ICP restarts. This environment uses 24, and it is worth knowing for real
  deployments: the symptom looks like a network problem and is not one.
- **auto-setup creates a database only when `DBNAME` differs from `POSTGRES_USER`.** Otherwise
  it assumes the Postgres container made one named after the role — so `temporal-postgres` sets
  `POSTGRES_DB` to the same value as its user, and `temporal_visibility` (which does differ) is
  created by auto-setup.
- **Temporal's frontend binds the container address, not loopback.** A healthcheck or CLI call
  against `127.0.0.1:7233` inside the container is refused; use `$(hostname -i):7233`.

## API paths worth knowing

The console's workflow routes are not symmetric, which costs time when scripting them:

| | |
|---|---|
| `GET  …/definitions` | definitions, from stored metadata |
| `GET  …/workflows` | instance list |
| `GET  …/workflows/{id}` | one instance (queries the workflow directly — no visibility needed) |
| `POST …/workflows` | **start** an instance |
| `POST …/workflows/{id}/{suspend\|resume\|terminate\|cancel}` | lifecycle |
| `GET  …/human-tasks`, `…/human-tasks/pending-count` | human-task views (role-gated — see Findings) |
| `POST …/human-tasks/{taskId}/complete` | complete a task: `{"result": {…}}` |

All of them are `…/icp/workflow/{componentId}/{environmentId}/…` and need a bearer token from
`POST /auth/login`.

## Layout

```
docker-compose.yml         networks, ICP node(s), Postgres, Temporal, integrations, edge
edge/                      the only container on both networks (pinned / round-robin)
icp/                       image built from your assembled distribution + config template
integrations/expense|orders Ballerina sources, Config.toml template, image
db/initdb/                 role, ICP schema (from the repo scripts), grants, credentials_db
artifacts/db/              SQL staged from the ICP repo — do not edit here
scripts/                   build-artifacts · bootstrap · grant-task-roles · smoke · db-scripts-test
```

Artifacts (`icp/artifacts`, `integrations/*/artifacts`, `artifacts/db`) are staged by
`build-artifacts.sh` and are not committed: they are builds of your branches, not sources.
