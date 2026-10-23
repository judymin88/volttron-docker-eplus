# EnergyPlus simulation

The simulation stack is defined in `docker-compose-sim.yml`. It starts PostgreSQL and the original VOLTTRON agents plus the EnergyPlus agent. The EnergyPlus input model and generated output files live under `simulation-data/building1` on the host. The inputs are copied from the agent's example model before each start so EnergyPlus can modify its working copy without changing the source model.

The image installs amd64 EnergyPlus 8.5.0, the Temurin Java 8 runtime, and BCVTB 1.6.0. BCVTB 1.6.0 is documented as tested with EnergyPlus 8.5 and Java 8. Its IzPack installer runs unattended using [bcvtb-auto-install.xml](configs/bcvtb-auto-install.xml), which sets `/opt/bcvtb` as the target path. The complete runtime is installed there, and the agent config points there for its Java runtime and `variables.dtd`.

## Start

From this directory, start the simulation stack:

```sh
mkdir -p simulation-data/building1
cp agents/EnergyplusAgent/eplus_config/building1/BUILDING1.idf simulation-data/building1/
cp agents/EnergyplusAgent/eplus_config/building1/USA_WA_Pasco-Tri.Cities.AP.727845_TMY3.epw simulation-data/building1/
LOCAL_USER_ID="$(id -u)" docker compose -f docker-compose-sim.yml up --build -d postgres volttron1
```

Follow VOLTTRON startup and agent logs:

```sh
docker compose -f docker-compose-sim.yml logs -f volttron1
```

Confirm that the image contains Java and the BCVTB runtime:

```sh
docker exec volttron1 java -version
docker exec volttron1 ls -l /opt/bcvtb/bin/BCVTB.jar /opt/bcvtb/lib/xml/variables.dtd
```

Wait for platform setup and the agents to finish installing and start before running `vctl status`; checking status during the first-time installer can interfere with setup. On a fresh VOLTTRON home, the expected identities are `listener`, `platform.driver`, `platform.agent`, `platform.actuator`, `platform.historian`, `volttron.central`, and `energyplus`.

The simulation platform config includes Listener, Platform Driver, Volttron Central Platform, Actuator, SQL Historian, Volttron Central, and EnergyPlus. The Docker startup installs agents only when it initializes a new VOLTTRON home. If the `volttron1` container is already initialized, newly added entries in `platform_config-sim.yml` are not installed automatically; install the missing agents with `volttron-ctl` or recreate the VOLTTRON container. PostgreSQL data is stored in a separate named volume.

When updating the EnergyPlus agent source after it has already been installed, reinstall the package so VOLTTRON uses the updated code:

```sh
docker exec -itu volttron volttron1 /home/volttron/.local/bin/volttron-ctl remove --tag energyplus
docker exec -itu volttron volttron1 /home/volttron/.local/bin/volttron-ctl install /home/volttron/energyplus-agent \
  --agent-config /home/volttron/configs/energyplus.config \
  --tag energyplus --vip-identity energyplus --start
```

## Access the PostgreSQL database

Run these commands from the repository root on the machine running Docker. The simulation uses the `postgres` service in [docker-compose-sim.yml](docker-compose-sim.yml), with these connection settings:

| Setting | Value |
| --- | --- |
| Database | `volttron` |
| User | `volttron` |
| Password | See `POSTGRES_PASSWORD` in `docker-compose-sim.yml` |
| Host within the Compose network | `postgres` |
| Port within the Compose network | `5432` |
| Container | `volttron-postgres` |
| Persistent volume | `volttron-postgres-data` |

The SQL Historian uses the matching settings in [configs/historian.config](configs/historian.config). The Compose file does not publish the database port to the host, so `localhost:5432` will not reach this database by default.

### Open a SQL prompt

If the simulation stack is already running, open `psql` directly:

```sh
docker compose -f docker-compose-sim.yml exec postgres psql -U volttron -d volttron
```

This uses the database container's local socket and does not normally prompt for a password. No PostgreSQL client installation is needed on the host. If the service is stopped, start it and check readiness first:

```sh
docker compose -f docker-compose-sim.yml up -d postgres
docker compose -f docker-compose-sim.yml exec postgres pg_isready -U volttron -d volttron
```

Inside `psql`, use these commands to inspect the database:

```sql
\conninfo
\dt
\d topics
\d data
SELECT topic_id, topic_name FROM topics ORDER BY topic_name LIMIT 20;
SELECT t.topic_name, d.ts, to_jsonb(d) AS stored_row
FROM data d JOIN topics t USING (topic_id)
WHERE t.topic_name LIKE 'devices/PNNL/BUILDING1/%'
ORDER BY d.ts DESC
LIMIT 20;
\q
```

`topics` maps topic IDs to names, and `data` stores timestamped readings associated with those IDs. The historian creates its tables when it initializes; starting PostgreSQL alone does not create historian tables. See the verification commands below for checking incoming simulation data.

### Export recent readings to CSV

This writes up to 1,000 recent EnergyPlus readings to `energyplus-readings.csv` in the current directory on the host:

```sh
docker compose -f docker-compose-sim.yml exec -T postgres \
  psql -U volttron -d volttron -v ON_ERROR_STOP=1 -c \
  "COPY (SELECT t.topic_name, d.ts, to_jsonb(d) AS stored_row FROM data d JOIN topics t USING (topic_id) WHERE t.topic_name LIKE 'devices/PNNL/BUILDING1/%' ORDER BY d.ts DESC LIMIT 1000) TO STDOUT WITH CSV HEADER" \
  > energyplus-readings.csv
```

### Connect with a desktop client or host-installed psql

For DBeaver, pgAdmin, or a PostgreSQL client on the Docker host, create an optional file named `docker-compose-postgres-local.yml` containing:

```yaml
services:
  postgres:
    ports:
      - "127.0.0.1:5433:5432"
```

Apply it alongside the simulation Compose file:

```sh
docker compose -f docker-compose-sim.yml -f docker-compose-postgres-local.yml up -d postgres
```

Connect to host `127.0.0.1`, port `5433`, database `volttron`, and user `volttron`, using the password configured in the simulation Compose file. With a host-installed client:

```sh
psql -h 127.0.0.1 -p 5433 -U volttron -d volttron -W
```

The mapping binds to the Docker host's loopback interface. If Docker runs on a remote machine, run `ssh -N -L 5433:127.0.0.1:5433 USER@DOCKER_HOST` on your workstation, replacing `USER` and `DOCKER_HOST`, then connect your desktop client to `127.0.0.1:5433` on the workstation. Continue including both Compose files in commands that recreate the database service if you want to keep this port mapping.

### Troubleshooting

- **Service is not running:** check `docker compose -f docker-compose-sim.yml ps -a postgres` and `docker compose -f docker-compose-sim.yml logs --tail=100 postgres`.
- **Connection refused from a desktop client:** confirm the optional port mapping is applied; use `127.0.0.1:5433` from the host and `postgres:5432` from containers on the Compose network.
- **Password authentication failed:** use the credentials with which the database volume was first initialized. Changing `POSTGRES_PASSWORD` in Compose does not reset an existing database user's password.
- **Table `data` or `topics` does not exist:** confirm the SQL Historian agent is installed and running, and inspect `docker compose -f docker-compose-sim.yml logs --tail=100 volttron1` for historian connection errors.
- **No EnergyPlus rows:** confirm the simulation is publishing and use the EnergyPlus topic filter below; older deployments may have unrelated rows.

Database contents persist in `volttron-postgres-data` across container restarts. Do not use `down -v` to troubleshoot access: it deletes the stack's persisted volumes.

## Verify simulation and historian data

The configured run covers August 1–31 at a 90× time scale, so the full simulation is expected to take about eight hours. Successful completion should leave `simulation-data/building1/eplusout.csv`.

Check that the CSV exists and has rows:

```sh
ls -lh simulation-data/building1/eplusout.csv
head -n 3 simulation-data/building1/eplusout.csv
```

Check that PostgreSQL is receiving EnergyPlus topics:

```sh
docker compose -f docker-compose-sim.yml exec postgres \
  psql -U volttron -d volttron -c 'SELECT COUNT(*) FROM data;'
```

Inspect recent values and confirm the topic names come from EnergyPlus:

```sh
docker compose -f docker-compose-sim.yml exec postgres \
  psql -U volttron -d volttron -c \
  'SELECT t.topic_name, d.ts, to_jsonb(d) AS stored_row FROM data d JOIN topics t USING (topic_id) ORDER BY d.ts DESC LIMIT 20;'
```

The total row count should grow while the simulation runs. To count just the EnergyPlus points:

```sh
docker compose -f docker-compose-sim.yml exec postgres \
  psql -U volttron -d volttron -c \
  "SELECT COUNT(*) FROM data d JOIN topics t USING (topic_id) WHERE t.topic_name LIKE 'devices/PNNL/BUILDING1/%';"
```

That count should grow, and the recent topic query above should show `devices/PNNL/BUILDING1/...` values.
The PostgreSQL volume may contain older `fake-campus/...` rows from a previous deployment; those do not count as EnergyPlus data.

## Stop

Stop the simulation without deleting its database volume:

```sh
docker compose -f docker-compose-sim.yml stop volttron1
```

Use `docker compose ... down -v` only if you intentionally want to delete persisted database data.
