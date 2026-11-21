---
title: ServerBox CLI
description: Manage a running desktop ServerBox instance from the terminal
---

Launch a macOS or Linux build from this checkout with `SBM_BRIDGE=on` in its
environment. The CLI works while that process runs. It uses the app's existing
server records and the same SSH and Monitor settings the editor uses.

```sh
dart tool/serverbox.dart servers list
dart tool/serverbox.dart servers add lab-primary \
  --ssh-ip 192.0.2.10 --ssh-port 2222 --ssh-user operator \
  --ssh-key "$HOME/.ssh/id_ed25519" \
  --monitor-addr https://monitor.example.test:3770 \
  --monitor-password-file "$HOME/.config/lab-monitor/password"
dart tool/serverbox.dart servers show SERVER_ID
dart tool/serverbox.dart status SERVER_ID
dart tool/serverbox.dart monitor check SERVER_ID
```

Successful commands write JSON to stdout. Errors go to stderr and return a
nonzero exit code. `status` reads the app's current sample and connection state.
`monitor check` authenticates and reads the agent's capabilities, independently
of which transport the app uses for its status polls.

Use a separate entry per IP if you want each address to appear in the list.
`--monitor-fallback URL` adds an alternate Monitor endpoint on the same entry.
Use `--ssh-jump ID` when SSH must go through another saved server.

```sh
dart tool/serverbox.dart servers set SERVER_ID --ssh-ip 192.0.2.11
dart tool/serverbox.dart servers set SERVER_ID --ssh-key "$HOME/.ssh/id_ed25519"
dart tool/serverbox.dart servers remove SERVER_ID --yes
```

The key stays in its local file. Run `dart tool/serverbox.dart keys list` for
stored key IDs, then use `--ssh-key-id` to select a key already imported into
the app. Setting a key clears the saved SSH password unless the same
command supplies `--ssh-password-file`. Password file flags also accept `-` for
stdin. Use `--allow-insecure-monitor` if you explicitly want to use remote
plaintext HTTP. `servers set` preserves fields omitted from the command.

## Local API

The app publishes a Unix socket path and bearer token in `bridge.json` with
file mode `0600`. On macOS the file is under
`~/Library/Application Support/ServerBox`. On Linux it is under
`$XDG_DATA_HOME/ServerBox`, defaulting to `~/.local/share/ServerBox`.
`SBM_BRIDGE_FILE` selects the discovery file for the CLI. The socket is inside
a user-private directory. Requests use HTTP over that socket with host
`localhost` and `Authorization: Bearer …`. Responses omit credentials.

| Method | Path | Operation |
| --- | --- | --- |
| GET | `/v1/health` | API version and app build |
| GET | `/v1/keys` | List stored key IDs and names |
| GET | `/v1/servers` | List records |
| POST | `/v1/servers` | Create a record |
| GET | `/v1/servers/{id}` | Read one record |
| PATCH | `/v1/servers/{id}` | Update supplied fields |
| DELETE | `/v1/servers/{id}` | Remove a record |
| GET | `/v1/servers/{id}/status` | Read the current sample |
| GET | `/v1/servers/{id}/monitor` | Verify Monitor capabilities |
