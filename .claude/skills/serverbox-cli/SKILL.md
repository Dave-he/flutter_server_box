---
name: serverbox-cli
description: Manage saved ServerBox servers through the desktop CLI. List or update entries, select SSH keys, configure Monitor endpoints, and inspect connection status.
---

# ServerBox CLI

Run from the ServerBox checkout while a build from this checkout is running
with `SBM_BRIDGE=on`.

```sh
dart tool/serverbox.dart servers list
dart tool/serverbox.dart servers show SERVER_ID
dart tool/serverbox.dart keys list
dart tool/serverbox.dart status SERVER_ID
dart tool/serverbox.dart monitor check SERVER_ID
```

Read the JSON output to choose the saved server ID. `status` gives the app's
current reading. `monitor check` makes an authenticated capability request.

```sh
dart tool/serverbox.dart servers add lab-primary \
  --ssh-ip 192.0.2.10 --ssh-user operator --ssh-port 2222 \
  --ssh-key "$HOME/.ssh/id_ed25519"
dart tool/serverbox.dart servers set SERVER_ID \
  --monitor-addr https://monitor.example.test:3770 \
  --monitor-password-file "$HOME/.config/lab-monitor/password"
```

Reference an existing private key by path with `--ssh-key` or a stored key by
ID with `--ssh-key-id`. Use `--monitor-fallback` for a second Monitor address,
or create one record per IP when the user wants separate entries. Run
`dart tool/serverbox.dart --help` for options and see
`docs/src/content/docs/development/cli.md` for setup and the local API.
