# Agent Cockpit — Installer

This repository holds **only the public bootstrap script** that installs the
Agent Cockpit connector on a computer you own. It contains no cockpit source, no
connector source, no configuration and no secret.

## Install a computer

Open Agent Cockpit in your browser, choose **„Computer verbinden"** and copy the
command shown there. It looks like this — the address, the certificate
fingerprint and the one-time code come from *your* cockpit:

```sh
curl -fsSL https://raw.githubusercontent.com/ChristianBrauchli/agent-cockpit-installer/main/install.sh \
  | sh -s -- --cockpit cockpit.example.org:8444 \
              --fingerprint sha256:… \
              --code ABCD-1234 \
              --name "Mein Mac"
```

What the command does, in order:

1. detects your operating system and architecture;
2. downloads the connector **from your cockpit**, over TLS pinned to the
   fingerprint in the command, and verifies its SHA-256 checksum;
3. installs OpenClaw (the agent engine) for your user, without administrator
   rights, keeping any existing installation and configuration;
4. registers a background service — `systemd --user` on Linux, `launchd` on
   macOS — so the connector starts again after a restart;
5. pairs this computer with your cockpit using the one-time code.

Everything is installed under `~/.agent-cockpit`. Nothing is installed globally,
no `sudo` is used, and no secret travels in the command: the code is valid once
and for fifteen minutes.

## macOS: the package, for people who would rather not use a Terminal

Each release also carries `AgentCockpit.pkg`. It installs two things:

* `/Applications/Agent Cockpit.app` — a tiny helper that registers the
  `agent-cockpit://` link scheme;
* `/usr/local/bin/agent-cockpit-install` — this same installer.

The cockpit's setup wizard then shows a **„Diesen Mac koppeln"** button whose link
carries the address, the certificate fingerprint and the one-time code. Clicking
it runs the helper, which installs the connector and pairs the Mac — nothing is
typed and no Terminal is opened.

The package is **unsigned and not notarised** (no Apple Developer ID is available
for it), so Gatekeeper warns on first launch and asks you to confirm. That is
expected, and it is stated in the package's own README rather than hidden.
Signing would only add `productsign`/`notarytool` steps around the same payload.

## Options

```sh
sh install.sh --help
```

| option | meaning |
| --- | --- |
| `--cockpit HOST:PORT` | the cockpit's download endpoint (required) |
| `--fingerprint sha256:…` | the cockpit's certificate fingerprint (required) |
| `--code CODE` | the one-time pairing code |
| `--repair` | keep the pairing and the agent data, install only what is missing and start the service again — what the cockpit's “Einrichtung reparieren” hands out |
| `--name NAME` | the name this computer shows in the cockpit |
| `--hub-host HOST` | override the pairing hub's address (default: from the cockpit) |
| `--hub-port PORT` | override the pairing hub's port (default: from the cockpit) |
| `--no-service` | do not register a background service |
| `--no-openclaw` | install the connector only |
| `--dry-run` | print what would happen, change nothing |
| `--uninstall` | remove the connector, keep your agent data |
| `--purge` | with `--uninstall`: also delete the agent data |

## Uninstall

```sh
sh install.sh --uninstall            # removes the connector; agent data stays
sh install.sh --uninstall --purge    # also removes sessions and the workspace
```

The cockpit entry for the computer is removed separately, in the cockpit, under
**„Verbundene Geräte"**.

## Security

* The download and the pairing channel are the *same* TLS certificate; the
  installer refuses a certificate whose SHA-256 fingerprint differs from the one
  in the command, so a substituted server is rejected rather than trusted.
* The connector dials **out** to your cockpit. Your computer needs no open
  inbound port, and the cockpit never learns your address.
* The connector presents a device token (stored hashed on the cockpit's side)
  and answers only a fixed list of named operations — there is no remote shell.
* This repository is public; your cockpit, your credentials and your agent data
  are not here.

## Releases

A tag of the form `v*` triggers `.github/workflows/release.yml`, which checks the
installer against `SHA256SUMS` and publishes a release carrying `install.sh` and
`SHA256SUMS` as assets.
