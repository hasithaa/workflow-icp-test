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

```
                icp-net                    │  edge  │            integration-net
  ┌──────────┐  ┌───────┐  ┌───────┐       │ (nginx │   ┌──────────┐  ┌──────────┐  ┌──────────┐
  │ postgres │  │ icp-1 │  │ icp-2 │◄──────┤  L4    ├──►│ expense  │  │  orders  │  │ temporal │
  └──────────┘  └───────┘  └───────┘       │ proxy) │   │  ×N      │  │   ×N     │  │ dev srv  │
                                           └────────┘   └──────────┘  └──────────┘  └──────────┘
                     ▲                                        │
                     └──── no route this way ─────────────────┘
```

`edge` is the only container on both networks, and it is a plain TCP proxy. An integration can
reach the ICP; the ICP cannot reach an integration. That is the property under test.

---

## Prerequisites

- Docker with **8 GB** available for the cluster profile (~3.5 GB for the default one).
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

# 3. Drive the workflow features and assert the outcomes.
./scripts/smoke.sh                # add --include-offline for the 503 check

# 4. Test the SQL scripts (fresh install vs migrated, on the running Postgres).
./scripts/db-scripts-test.sh
```

Console: <https://localhost:9446> (`admin` / `admin`, self-signed certificate).
Temporal UI: <http://localhost:8233>. Postgres: `localhost:55432` (`postgres`/`postgres`).

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

19 assertions, all through the ICP's own HTTP API:

- both integrations registered, each with the expected number of RUNNING runtimes;
- both promoted to `ballerinaWorkflow` on their first full heartbeat (the auto-registration
  fix — a component auto-created from a heartbeat otherwise stays `service` and shows no
  Workflows view);
- every runtime published its descriptor and advertises `workflowCommands`;
- definitions listed per integration, **from stored metadata** — no request into the runtime;
- `expenseApproval` starts through the tunnel (HTTP 201), reaches RUNNING, and its human-task
  child workflow exists in Temporal;
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
- **Human-task listings need Temporal visibility the dev server does not serve.**
  `humanTasks.list` and `humanTasks.pendingCount` round-trip correctly and answer an empty
  page. The tunnel is not what is limited — the command reaches the integration and executes.
  The smoke test therefore verifies the task in Temporal and reports the listing as a note.
  Point the integrations at a full Temporal deployment if you need those views.
- **Temporal here is in-memory.** A file-backed dev server needs a writable volume, and a named
  volume arrives root-owned while the image runs as uid 1000 (SQLite then fails with CANTOPEN,
  reported as "out of memory"). Restarting `temporal` drops in-flight instances — restart the
  integrations after it.

## API paths worth knowing

The console's workflow routes are not symmetric, which costs time when scripting them:

| | |
|---|---|
| `GET  …/definitions` | definitions, from stored metadata |
| `GET  …/workflows` | instance list |
| `GET  …/workflows/{id}` | one instance (queries the workflow directly — no visibility needed) |
| `POST …/workflows` | **start** an instance |
| `POST …/workflows/{id}/{suspend\|resume\|terminate\|cancel}` | lifecycle |
| `GET  …/human-tasks`, `…/human-tasks/pending-count` | human-task views (see the visibility note) |

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
scripts/                   build-artifacts · bootstrap · smoke · db-scripts-test
```

Artifacts (`icp/artifacts`, `integrations/*/artifacts`, `artifacts/db`) are staged by
`build-artifacts.sh` and are not committed: they are builds of your branches, not sources.
