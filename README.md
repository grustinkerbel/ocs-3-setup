# OCS Inventory 3.0 – Docker Deployment Runbook

Automation for the official OCS Inventory 3.0 Docker stack (backend API, nginx proxy,
PostgreSQL 15, web console). Based on the official "Running OCS Inventory Server with Docker" guide.

> **Status warning:** 3.0 is currently a **release candidate (RC)**, intended for testing.
> Use this for a test/pilot server alongside your 2.x production system, not as a replacement yet.

## Files

| File | Purpose |
|---|---|
| `ocs-setup.sh` | Deploy and operate the stack (preflight, Docker install, configure, backup, restore, upgrade) |
| `ocs-setup.conf.example` | Settings template. Copy to `ocs-setup.conf` |

## Design notes

- The official `docker-compose.yml` is **never edited**. Your settings go in a generated
  `docker-compose.override.yml`, so upgrading = swap the official file, regenerate the override.
- The DB password is generated once and stored in `/opt/ocsinventory-server/.ocs-secrets` (mode 600).
  Re-runs reuse it. This matters: Postgres only reads its credentials when the data volume is first created.
- All actions are logged to `/var/log/ocs-setup.log`.
- Commands are safe to re-run (idempotent).

## Prerequisites

- Ubuntu/Debian or RHEL-family (RHEL, Rocky, Alma, CentOS) host, root access
- 2 GB RAM and 10 GB free disk minimum (adjust `MIN_RAM_MB` / `MIN_DISK_GB` to taste; size up for large fleets)
- DNS record for the server (agents and browsers must resolve it)
- Outbound access to `raw.githubusercontent.com`, `download.docker.com`, and Docker Hub
  (or an internal mirror)
- Ports 80, 443, 8080 free (configurable)

## Quick start

```bash
sudo mkdir -p /opt/ocs-setup && sudo cp ocs-setup.sh ocs-setup.conf.example /opt/ocs-setup/
cd /opt/ocs-setup
sudo cp ocs-setup.conf.example ocs-setup.conf
sudo chmod 600 ocs-setup.conf
sudo nano ocs-setup.conf        # set OCS_HOSTNAME at minimum
sudo bash ocs-setup.sh preflight
sudo bash ocs-setup.sh all
```

Then open `http://<OCS_HOSTNAME>:8080`. The initial admin login is **not stated in the Docker guide**;
check the official 3.0 documentation.

## Commands

| Command | What it does |
|---|---|
| `all` | preflight, install-docker, firewall, fetch, configure, up |
| `preflight` | OS, RAM, disk, ports, DNS, download/registry reachability |
| `install-docker` | Docker Engine + compose plugin from Docker's official repo |
| `firewall` | Opens ports in ufw/firewalld if one is active |
| `tlscheck` | Validates certificate, key, hostname coverage and expiry; changes nothing |
| `selfsigned` | TEST ONLY: creates a self-signed cert if no cert files exist yet |
| `netcheck` | Diagnoses Docker subnet collisions (actual vs. configured subnet, overlaps) |
| `cleanup [opts]` | Removes the stack's containers/network; `--volumes`/`--purge` also reset the database |
| `fetch` | Downloads the official compose + nginx files for `OCS_VERSION` |
| `configure` | Generates the override file; validates with `docker compose config` |
| `up` | Pulls images, starts the stack, waits until the API and console respond |
| `health` | Container status + HTTP checks (non-zero exit on failure, usable in monitoring) |
| `backup` | `pg_dump` + config + console volumes to `BACKUP_DIR`, prunes old backups |
| `restore <db.sql.gz>` | Safety backup, then restores the dump |
| `upgrade <version>` | Backup, shows diff of official files, applies new version |

## Routine operations

**Scheduled backup** (root crontab):

```
0 2 * * * /opt/ocs-setup/ocs-setup.sh backup >/dev/null 2>&1
```

Copy `BACKUP_DIR` off the server (NAS, object storage). A backup on the same disk is not a backup.
Backups contain the DB password and config, so keep them access-controlled.

**Upgrading RC1 to RC2 or later:**

```bash
sudo bash ocs-setup.sh upgrade 3.0.0-rc2
```

Read the diff it prints. In particular, a PostgreSQL **major** version change in the compose file
requires a dump/restore, not a simple image pull.

**Restore test:** do this once on a scratch VM before you rely on the backups.

## TLS (HTTPS)

Set `OCS_SCHEME="https"` and place your certificate files in `/opt/ocsinventory-server/certs/`
(or point `TLS_*_FILE` elsewhere):

| File | Contents |
|---|---|
| `fullchain.pem` | Server certificate **followed by** intermediates |
| `privkey.pem` | Private key, **unencrypted** (nginx cannot prompt for a passphrase), `chmod 600` |
| `ca.crt` | Optional CA certificate |

```bash
sudo bash ocs-setup.sh tlscheck     # validate first
sudo bash ocs-setup.sh configure && sudo bash ocs-setup.sh up
```

What `configure` does when TLS is on:

1. **Validates the certificate:** key matches cert, not expired (warns at 30 days), covers `OCS_HOSTNAME`
   (wildcards handled), warns on missing intermediates or a world-readable key. It refuses to continue
   on a hard failure rather than starting a broken proxy.
2. **Generates `files/nginx/ocsinventory-tls.generated.conf` from the official nginx config**, so static
   files and uwsgi settings stay in sync with upstream. If the official file's layout ever changes
   unexpectedly, the script stops instead of guessing.
3. **Serves three listeners:** port 80 (redirect to HTTPS, or the API if `HTTP_MODE=serve`), 443 for the
   API/agents, and `FRONTEND_PORT` for the web console, now over TLS. The console's own container is
   no longer published directly; the proxy fronts it.
4. Mounts the config and certs read-only into the proxy, points `FRONTEND_REDIRECT_ENV` and
   `BACKEND_API_ROUTE_ENV` at `https://` URLs, and runs `nginx -t` inside the real proxy image.

`health` then verifies the certificate **strictly** (no `-k`) against this server's trust store, so a
missing intermediate or wrong hostname shows up immediately. Browsers on your network are what
ultimately matter, so also open the console from a workstation.

**Renewal:** after replacing the cert files, run `docker compose -f /opt/ocsinventory-server/docker-compose.yml restart ocsinventory-proxy`
(nginx reads certificates at start). Wire this into whatever process renews your wildcard certificate.

**Agents:** the 3.0 agent endpoint is the same hostname on 443. If legacy 2.x agents cannot
follow a redirect, set `HTTP_MODE="serve"` during migration, and move agents to HTTPS before switching back to `redirect`.

## Docker network / subnet collisions

**Symptom:** the backend restarts with `django.db.utils.OperationalError: connection to server at
"ocsinventory-db" (172.18.0.3)...`. Docker gave the OCS network a range your LAN already uses, so traffic
between containers is routed to the physical network instead of the Docker bridge.

**Fix:** set a subnet nobody else uses, and list the ranges your network does use:

```bash
# in ocs-setup.conf
RESERVED_RANGES="172.16.0.0/16 172.17.0.0/16 172.18.0.0/16"
DOCKER_SUBNET="172.20.0.0/24"
```
```bash
sudo bash ocs-setup.sh netcheck          # shows actual vs. configured subnet, container IPs, overlaps
sudo bash ocs-setup.sh configure
sudo bash ocs-setup.sh up                # offers to recreate the network; volumes/data are kept
```

How it works and what to know:

- Compose will not change the subnet of an existing network, so `up` detects the mismatch and runs
  `docker compose down` (**without `-v`**, so the database and console volumes survive) before recreating it.
- The collision check reads this host's routing table plus `RESERVED_RANGES`. **It cannot see LAN ranges that are
  only reachable through the default gateway**, so `RESERVED_RANGES` is the reliable part; fill it in from your IP plan.
- Container IPs are assigned automatically; the service names (`ocsinventory-db`, ...) resolve inside the network,
  so the static addresses your 2.x file used are not needed.
- Other Docker projects on the same host can still collide. For a host-wide fix, set `default-address-pools`
  (and optionally `bip` for `docker0`, which defaults to 172.17.0.0/16) in `/etc/docker/daemon.json`, then restart Docker.
  This restarts every container on the host, so plan a window. The script does not touch daemon settings.
- `172.20.0.0/24` sits in the private RFC 1918 block (172.16.0.0/12) and does not overlap 172.16/17/18. A /24 has 254
  usable addresses, ample for the 4 containers plus the temporary extras Docker creates during upgrades, and it leaves
  the rest of 172.20.x.x free. For additional Docker networks on the same host, use other /24s (e.g. 172.20.1.0/24)
  rather than widening this one. The script cannot know whether this range is used elsewhere on your network (VPNs,
  other sites, other Docker hosts), so confirm that and list any other in-use ranges in `RESERVED_RANGES`.

## Cleanup and reset

```bash
sudo bash ocs-setup.sh cleanup --dry-run --purge   # preview exactly what a full reset would remove
sudo bash ocs-setup.sh cleanup                     # containers + network only; data kept
sudo bash ocs-setup.sh cleanup --volumes           # ALSO delete the database/console volumes (data loss)
sudo bash ocs-setup.sh cleanup --purge             # full reset: --volumes + generated files
```

| Option | Removes | Keeps |
|---|---|---|
| *(none)* | containers, network | all volumes (database, console config), all files |
| `--volumes` | + the stack's volumes | your files |
| `--purge` | + `.ocs-secrets`, override, `.env`, generated nginx conf | `ocs-setup.conf`, `certs/`, official compose/nginx files |

**Scope.** Cleanup only touches resources belonging to this stack: the compose project label, plus containers
started from `OCS_DIR` under a different project name (leftovers from earlier runs). It never runs
`docker system prune` and never touches other containers, networks or volumes on the host. If a **different**
stack, such as your 2.x server on the same host, uses OCS's fixed container names (`ocsinventory-db`,
`ocsinventory-proxy`), cleanup lists them, leaves them alone, and tells you they will block this stack from starting.

**Safety.** `--volumes`/`--purge` try a backup first (if the database is up), then require you to type `DELETE`
(or pass `--yes`). Use `--no-backup` to skip the backup step.

### Why you get "password authentication failed" when re-running

Postgres applies `POSTGRES_PASSWORD` **only when its data volume is first created**. Containers and networks can be
destroyed and recreated freely, but the volume keeps the original password. If a later run generates or
configures a different password (deleted `.ocs-secrets`, edited `DB_PASSWORD`, changed `DB_USER`/`DB_NAME`),
the backend is rejected. So **removing containers and networks alone does not fix it; the volume must be reset.**

The script now guards against this: `configure` refuses to continue when a database volume exists and the
credentials would not match it (missing `.ocs-secrets`, or changed `DB_PASSWORD`/`DB_USER`/`DB_NAME`),
and explains the choices. `health` also recognises the error in the backend logs. To start clean after a mismatch:

```bash
sudo bash ocs-setup.sh cleanup --volumes --purge
sudo bash ocs-setup.sh configure && sudo bash ocs-setup.sh up
```

Experts who really know the credentials match can bypass the guard with `OCS_ALLOW_DB_MISMATCH=1`.

## Known gaps / decisions still open

1. **TLS is opt-in.** With `OCS_SCHEME="http"` all traffic, including logins and inventory data, is unencrypted. Enable HTTPS before pointing real agents at it.
2. **Docker published ports bypass ufw.** Restrict access at the network firewall too.
3. **Default credentials in the official compose file are weak** (`ocsuser`/`ocsuser`). The script
   overrides them with a random password; verify with `docker compose config` if you want to see
   the final merged values.
4. **TLS and custom ports** require Docker Compose 2.24+ (uses the `!override` / `!reset` tags).
5. **Custom DB user/name:** the official healthcheck hard-codes `ocsuser`/`ocsdb`; when you change them, `configure` overrides the healthcheck to follow your values.
6. **Data migration from 2.x** is not covered here. See the official migration guide.

## Migrating from 2.x (strategy)

The project describes three approaches (parallel agents, proxy duplication, full replacement), and
3.0 includes a compatibility module so existing 2.x agents can report to the 3.0 backend.
For a production asset system, the safe path is:

1. Stand up this 3.0 test server (done by this runbook).
2. Point a **small pilot group** of 2.x agents (or a duplicated feed) at it. Compare inventory against 2.x.
3. Check what you rely on in 2.x (SNMP scans, IPDiscover, package deployment, plugins, reports,
   LDAP/SSO) against the 3.0 feature set before committing.
4. Cut over only after the final (non-RC) release and a successful restore test.

## Troubleshooting

| Symptom | Check |
|---|---|
| Backend restarting with `OperationalError ... 172.x` | Docker subnet collides with your LAN: see "Docker network / subnet collisions" above |
| Backend restarting (other causes) | `docker compose -f /opt/ocsinventory-server/docker-compose.yml logs ocsinventory-backend` (DB credentials, DB not healthy yet, failed migration) |
| 502/504 from proxy | Backend not ready or crashed; check the shared socket volume and backend logs |
| Console can't reach the API | `BACKEND_API_ROUTE_ENV` must be the URL the **browser** uses (check `OCS_HOSTNAME`/ports), not an internal Docker name |
| `password authentication failed` | The DB volume was created with different credentials. See "Cleanup and reset" above. `cleanup --volumes` resets it (**deletes data**) |
| `docker compose down -v` | Permanently deletes all inventory data. Don't use it casually. |
