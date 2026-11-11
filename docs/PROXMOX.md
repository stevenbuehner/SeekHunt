# SeekHunt on Proxmox VE

This independent installer uses the [Proxmox Community Scripts framework](https://github.com/community-scripts/core),
with separate `ct/seekhunt.sh` and `install/seekhunt-install.sh` entrypoints. It
is not an official Community Script. The framework is pinned to commit
`39ac4530299dd2c0d8c162a4bd7b1b9c826dd5c8`.

## Installation

Publish these files to **`stevenbuehner/SeekHunt`, branch `proxmox/main`**, before
using the command below. An unpublished branch or a branch without the installer
will return an HTTP error. The installer does not fall back to `main`.

Run as root in the **Proxmox VE host shell**:

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/stevenbuehner/SeekHunt/proxmox/main/ct/seekhunt.sh -o /tmp/seekhunt.sh && bash /tmp/seekhunt.sh
```

The Community Scripts wizard selects storage and networking and creates an
unprivileged **Debian 13 LXC** with **2 CPU cores, 2048 MiB RAM and a 6 GiB disk**
by default. Advanced mode can change these settings. Supported CPU architectures
are amd64 and arm64; workerd requires the CPU features described in its
[platform requirements](https://github.com/cloudflare/workerd#running-workerd).
The installer needs internet access to GitHub, the Debian/Node.js package sources
and npm. It uses the framework's normal network setup and update bootstrap.

The application source is the snapshot of **`proxmox/main`** at a resolved full
commit SHA, downloaded from GitHub's archive endpoint. There is no Git clone,
Git history or download of other branches. The snapshot includes that commit's
files, including the workspace packages required to build SeekHunt.

Installation sets up Node.js 24, runs `npm ci`, builds the production web app
with `npm run build`, and bundles the existing Worker for `workerd`. It does
not start Vite or `wrangler dev`, and needs no Cloudflare account or API token.
`workerd` and esbuild come from the exact versions locked under Wrangler in
`package-lock.json`; there is no separate global or `latest` runtime install.

The systemd service starts automatically and serves **HTTP on port 8787**.
The framework also provides the usual `update` command inside the container.

## Nginx and HTTPS

Point your existing HTTPS reverse proxy at `http://LXC_IP:8787`. Use the
[`nginx.conf.example`](../scripts/proxmox/nginx.conf.example) location in your
existing TLS server block, replacing `SEEKHUNT_LXC_IP`. It forwards both the web
app and `/api/` and `/ws/` under the same public origin. WebSocket Upgrade
headers and a longer idle timeout are required; see
[Nginx's WebSocket documentation](https://nginx.org/en/docs/http/websocket.html).

Keep the external HTTPS URL at the root of its domain, for example
`https://seekhunt.example.org/`, rather than a subpath. Phones need trusted
HTTPS for GPS and camera access. The container itself does not install a TLS
certificate. It respects the proxy's `X-Forwarded-Proto` header; restrict access
to the internal HTTP port to your proxy/trusted network in your firewall.
Map tiles still load from the existing external map provider.

## Updates

Run as root **inside the SeekHunt LXC**:

```bash
update
```

Or from the Proxmox host, replacing `CTID` with the container ID:

```bash
pct exec CTID -- update
```

The updater resolves the latest commit of `proxmox/main`. An unchanged commit
is a no-op. Otherwise it downloads that commit's archive and builds a separate
release while the old server continues running. A lock prevents simultaneous
updates. Builds run as the unprivileged `seekhunt` user; the active release is
made root-owned and the service can write only its state directory.

After building, the updater stops the service, creates a consistent backup of
room storage, configuration and the systemd unit, switches the release symlink,
and starts the service. It checks both web assets and a dedicated internal
Durable Object through `/_health`, and verifies the running commit. No actual
game is created by this health endpoint and it returns no player/room data.
If startup fails, it restores the previous release and the saved storage and
configuration, then tries to restart that version. Failure to restore is
reported with the backup path and journal command; a backup is never a
substitute for an external container backup.

Clients reconnect after the brief interruption. Saved rooms survive successful
updates and restarts. Game timers continue to use wall-clock time, so a restart
does not pause a running game. On rollback, rooms return to their pre-update
snapshot. The two most recent application releases and three most recent
pre-update state backups are retained. Backups contain sensitive game data;
they are root-readable only and can outlive the application's 12-hour room
cleanup. Their retention is by update count, not age.

**Storage limitation:** workerd's `durableObjectStorage.localDisk` is explicitly
[experimental and subject to incompatible changes](https://github.com/cloudflare/workerd/blob/v1.20261019.1/src/workerd/server/workerd.capnp#L793).
A runtime version changes only when the branch's lockfile changes. Review
workerd upgrades and keep external Proxmox backups before making them. This
installation has one workerd process and local storage; it is not a distributed
Durable Objects deployment. It does not import existing Cloudflare rooms.

## Files and operations

| Location | Purpose |
| --- | --- |
| `/opt/seekhunt/current` | Active release symlink |
| `/opt/seekhunt/previous` | Previous successful release |
| `/opt/seekhunt/releases/` | Branch snapshots, builds and locked dependencies |
| `/var/lib/seekhunt/` | Persistent Durable Objects/SQLite files; never publicly served |
| `/etc/seekhunt/seekhunt.env` | HTTP configuration (`LISTEN_ADDRESS`, `PORT`) |
| `/etc/seekhunt/version.json` | Installed commit and workerd version |
| `/etc/systemd/system/seekhunt.service` | systemd unit |
| `/usr/local/lib/seekhunt/manage.sh` | Installed updater, promoted after successful startup |
| `/var/backups/seekhunt/` | Stopped-service backups; filename includes the saved commit |

```bash
systemctl status seekhunt
journalctl -u seekhunt -n 100 --no-pager
curl -fsS http://127.0.0.1:8787/_health
cat /etc/seekhunt/version.json
```

The default bind address is `0.0.0.0`. `127.0.0.1` is supported when your proxy
runs inside the same container. After changing the environment file, restart
with `systemctl restart seekhunt` and update your proxy's upstream port if
needed. Keep at least 1.5 GiB free plus the size of room storage before an
update; the updater checks this before downloading. Expand the 6 GiB disk if
dependencies or stored rooms grow. Updates install application dependencies
from the lockfile, not Debian or Node.js upgrades; maintain those separately.

For manual disaster recovery, stop the service first, retain the failed state
for diagnosis, and restore the selected archive into `/` (it contains
`var/lib/seekhunt`, `etc/seekhunt`, and `etc/systemd/system/seekhunt.service`).
Restore the matching application release identified by the full commit in the
backup filename before starting the service. Do not restore SQLite files into
a running process or mix an old backup with a newer runtime. The automatic
rollback performs these steps for a failed update.

## Verification scope

The installer/helper changes are reviewed with shell/JavaScript syntax checks
and static inspection, following the repository's workflow-script verification
policy. They have not been executed on a Proxmox host as part of authoring.
Real host provisioning, local Durable Object recovery/alarms, browser reconnects
and your external HTTPS proxy need verification on your own Proxmox installation.
Existing Cloudflare deployment and gameplay code are unchanged.

## Resumen en español

El instalador crea un LXC Debian 13 sin privilegios con 2 CPU, 2 GiB de RAM y
6 GiB de disco. Ejecuta `workerd` mediante systemd y sirve HTTP en el puerto
8787 detrás de tu proxy Nginx HTTPS. Descarga únicamente una instantánea de
la rama `proxmox/main`, sin historial Git ni otras ramas, instala las
dependencias con `npm ci` y compila la aplicación. Publica primero esa rama
con los archivos del instalador y ejecuta el comando de instalación anterior
en la consola del host Proxmox.

Para actualizar, ejecuta `update` como root dentro del LXC. La nueva versión
se compila antes de detener el servicio; se guardan los datos y la
configuración, y un fallo de arranque intenta restaurar la versión anterior.
Las partidas sufren una breve desconexión y sus relojes continúan avanzando.
Se conservan dos versiones y tres copias previas a actualizaciones; estas
copias pueden contener ubicaciones y permanecer más de doce horas.
El almacenamiento local de Durable Objects es experimental: la versión de
`workerd` queda fijada por el lockfile y se recomiendan copias externas de
Proxmox antes de cambiarla. Los scripts aún requieren verificación en un
host Proxmox real; no se ha realizado un despliegue durante su preparación.
