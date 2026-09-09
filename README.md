# Backhaul Auto Installer

Two interactive installer scripts for a reverse Backhaul tunnel using `wssmux`.

## Architecture

- Iran server: Backhaul **Server**
- Foreign server: Backhaul **Client**
- Default control port: `443`
- Default public client port on Iran: `2053`
- Default foreign target: `127.0.0.1:2053`
- Backhaul version: `v0.7.2`

## Iran server

Run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/istesinstitute-byte/backhaul-auto-installer/main/install-backhaul-iran.sh)
```

The script asks for:

- Iran public IP
- control port (default `443`)
- public client port (default `2053`)
- target host on foreign server (default `127.0.0.1`)
- target port on foreign server (default `2053`)
- optional 64-character token; press Enter to generate one automatically

It installs Backhaul, creates a self-signed TLS certificate, writes `/etc/backhaul/server.toml`, and creates/enables `backhaul-server.service`.

Keep the generated token private and use it on the foreign server.

## Foreign server

Make sure the target application (for example Xray) is already listening on the expected local address/port, usually `127.0.0.1:2053`.

Run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/istesinstitute-byte/backhaul-auto-installer/main/install-backhaul-foreign.sh)
```

The script asks for:

- Iran public IP
- control port on Iran (default `443`)
- local target host (default `127.0.0.1`)
- local target port (default `2053`)
- the 64-character token generated on the Iran server

It tests TCP connectivity to the Iran server, checks the local target, installs Backhaul, writes `/etc/backhaul/client.toml`, and creates `backhaul-client.service`.

## Migration warning

Do not run two foreign Backhaul Clients simultaneously with the same token unless you intentionally want the control channel to move/reset.

During migration, prepare the new foreign server first. When ready:

```bash
# old foreign server
systemctl stop backhaul-client

# new foreign server
systemctl enable --now backhaul-client
```

Rollback if needed:

```bash
# new foreign server
systemctl stop backhaul-client

# old foreign server
systemctl start backhaul-client
```

## Status checks

Iran:

```bash
systemctl status backhaul-server --no-pager -l
journalctl -u backhaul-server -n 30 --no-pager
ss -lntp | grep -E ':(443|2053)\b'
```

Foreign:

```bash
systemctl status backhaul-client --no-pager -l
journalctl -u backhaul-client -n 30 --no-pager
```

Successful connection should include:

```text
control channel established successfully
```

## Security

- Never publish or share `/etc/backhaul/token`.
- The scripts do not contain hard-coded tokens or passwords.
- If you make this repository public, only the installer code is public; runtime secrets stay on the servers.
