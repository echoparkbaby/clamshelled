# Clamshelled

**[Download](https://github.com/echoparkbaby/clamshelled/releases/download/v1.0.0-rc1/Clamshelled-1.0RC1.dmg)** ·
**[clamshelled website](https://echoparkbaby.github.io/clamshelled/)**

A macOS menu-bar app (menulet) that toggles **clamshell / lid-closed sleep** on
and off, with a state indicator in the menu bar.

- **ON**  → `pmset -a disablesleep 1` — the Mac stays awake with the lid
  closed (no external display/power required).
- **OFF** → `pmset -a disablesleep 0` — normal behaviour restored.

The privileged call runs through a small root helper (see below), not `sudo`.

> **What ON really does.** `disablesleep 1` disables *all* sleep, not just the
> lid-closed kind: no idle sleep, and the Apple menu's Sleep item greys out.
> That's what makes clamshell mode work, but it also means more battery use and
> a warm machine in a bag. Turn it off when you're done. The setting is
> **system-wide and survives a reboot**, so Clamshelled asks before quitting
> while it's on.

The menu-bar icon reflects the live state:

| State | Icon | Meaning |
|-------|------|---------|
| ON  | closed MacBook (it's *clamshelled*) | Lid-closed stays awake |
| OFF | open MacBook | Sleeps normally |

Both are template images, so they adapt to a light or dark menu bar. It polls
every 5 s, so changes made elsewhere (e.g. `pmset` in a terminal) are reflected
too.

> **This is a laptop feature.** Clamshell sleep only exists on a MacBook — run
> Clamshelled there, not on a desktop Mac (a Studio/mini has no lid).

## Build

```bash
cd "~/Swift Projects/clamshelled"
bash scripts/package.sh      # → Clamshelled.app
```

Then drag `Clamshelled.app` to `/Applications`. Enable **Launch at Login** from
its menu (or add it in System Settings → General → Login Items).

For a quick dev run without bundling: `swift run`.

## One-time setup: approve the privileged helper

Changing `disablesleep` needs root. Clamshelled ships a tiny **privileged helper**
(a LaunchDaemon registered with `SMAppService`) instead of a sudoers rule — so
there is no Terminal step and nothing written to `/etc`.

1. Drag **Clamshelled.app** to **/Applications**. This is required: a LaunchDaemon
   resolves its program *inside* the app bundle, so registering from a disk image
   or a movable folder leaves a root job pointing at a path that can vanish. The
   app refuses to register from anywhere else.
2. Open it and click **Install Privileged Helper…** (or just use the toggle — it
   offers).
3. macOS parks the helper pending approval. Turn on **Clamshelled** under
   **System Settings → General → Login Items & Extensions → Allow in the Background**.

Both sides pin each other's Developer ID code signature, so no other process can
drive the root helper, and the app won't talk to an impostor helper.

**Removing it:** menu → *Privileged Helper (Installed)* → **Remove Helper**. If
sleep is currently disabled, Clamshelled restores normal sleep *first* and
confirms it — removing the helper while the Mac is set never to sleep would strand
it awake with nothing left to undo it.

**Scripted / MDM deployment:**

```bash
/Applications/Clamshelled.app/Contents/MacOS/clamshelled --install-helper
/Applications/Clamshelled.app/Contents/MacOS/clamshelled --helper-status
/Applications/Clamshelled.app/Contents/MacOS/clamshelled --uninstall-helper
```

These exit non-zero on failure. Approval is still a user action.

**Upgrading:** a running helper is not replaced automatically by launchd, so the
app checks the running helper's generation at launch and re-registers if it is
stale. The helper also exits after two minutes idle.

## Layout

- `Sources/clamshelled/` — the menu-bar app.
  - `main.swift` — entry point + CLI flags (`--self-test`, `--*-helper`).
  - `AppController.swift` — `NSStatusItem`, menu, alerts, termination guard.
  - `HelperClient.swift` — XPC to the root helper; registration + update logic.
  - `SleepState.swift` — unprivileged `pmset -g` read and its parser.
- `Sources/ClamshelledHelper/` — the root LaunchDaemon (one privileged method).
- `Sources/ClamshelledShared/` — the XPC contract + code-signing requirements.
- `helper/…​.plist` — LaunchDaemon plist, embedded at `Contents/Library/LaunchDaemons/`.
- `scripts/package.sh` — builds universal, embeds + signs helper inner-to-outer,
  and **asserts both XPC code-signing requirements**.
- `scripts/release.sh` — package → DMG → notarize → staple.

## Tests

```bash
Clamshelled.app/Contents/MacOS/clamshelled --self-test   # pmset parser checks
```

Uses `precondition`, so the checks are live in the release binary too.

## Support

Clamshelled is free. If it saves you some hassle, a tip is always appreciated. I got kids!

[<img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="48" />](https://buymeacoffee.com/echoparkbaby)

## License

MIT — see [LICENSE](LICENSE).
