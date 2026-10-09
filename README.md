# Studio Sync

Studio Sync is one Studio plugin that keeps the test places of CloudSeekers, Flooded and Emblem
Tales on each game's green `main`, with nobody connecting Rojo. It syncs only the places listed in
`studio-sync/Config.luau`:

| Game | Repository | Places |
| --- | --- | --- |
| CloudSeekers | `AizaiDev/CloudSeekers` | Cloud Seekers Testing, Fast Testing Baseplate |
| Flooded | `ExZeret/Flooded` | TEST ENV, the hub |
| Emblem Tales | `EmblemTales/main` | the Testing Hub, the Testing World, the Arena place |

Any other place, a public game's included, it leaves alone.

## Installing it

Download `StudioSync.rbxm` from the **Studio Sync** release on this repository's Releases page,
which CI rebuilds from every green `main`. In Studio, open the Plugins tab > Plugins Folder, put
the file there and restart Studio, which loads a plugin only at launch.

Then take the old per-game plugins out of that folder: `CloudSeekersSync.rbxm`, `FloodedSync.rbxm`
and `EmblemTalesSync.rbxm`. Left in, they sync the same places a second time and keep reading each
other's settings.

From a clone, the build script can put the plugin in Studio's plugins folder itself:

```bash
powershell -ExecutionPolicy Bypass -File scripts/build-plugin.ps1
```

The first time it runs in each place, Studio asks whether it may reach `api.github.com`; allow it.
If Studio also asks whether it may edit scripts, allow that too.

## Tokens

The game repositories are private, and each belongs to a different GitHub account, so the plugin
keeps one read-only token per account: `AizaiDev`, `ExZeret` and `EmblemTales`. You need only the
tokens for the games you work on. The first time you open one of a game's places, a box above the
status pill asks for that account's token; paste it and press Save or Enter. The plugin checks it
with GitHub and keeps it in this computer's Studio plugin settings, so every place of that game
uses it from then on. If GitHub ever refuses it (it expired, was revoked or lost access), the pill
turns red and the box comes back for a new one.

The account's owner makes the token: in GitHub's Settings > Developer settings > Fine-grained
tokens, choose the account as the resource owner, only the game's repository, and Read on
Contents, Actions and Metadata. For the EmblemTales organization, an owner may also need to approve
it under the organization's Settings > Personal access tokens. Send a token in a private message,
never in a repository or a thread.

Any of those tokens also reads this repository, because it is public, which is how the plugin
updates itself.

## What it does

A pill in the bottom-left of the viewport shows what your Studio is doing: green when it matches
`main`, amber while it waits or works, red when it needs you, grey with Auto-sync off. Hover it for
the title of the commit the place matches and whether it is the latest `main`. Click it for the
full status and the last change list; the toolbar's **Status** button hides it.

It updates itself. The installed plugin is a small loader (`studio-sync-loader/`); the code that
syncs (`studio-sync/`) comes from this repository's `main` once its `ci` workflow is green, so a
change to it reaches every Studio at the next check. If that code fails to start, or does not
finish a check within a minute and a half, the plugin goes back to the version it was running and
prints why to Output; a version that finished a check is the one it starts with next time.
Reinstall the plugin only when Output says this repository has a newer loader.

While a synced place is open in Edit mode, it checks the game's `main` every 20 seconds. When the
`ci` workflow on `main`'s head commit is green, it writes what changed into that place, mapped
through the place's project file: new instances are created, edited scripts get their new source,
and an instance git removed since the last synced commit is removed too, unless it still holds
children. An instance kept for its children is reported on every sync after that, until someone
deletes it or git maps it again. It never touches assets, and it leaves alone a Studio-only folder
or script that shares a name with a new git script. Each sync prints its change list to Output.

Every five minutes it also compares the place with the commit it last synced, even when nothing
has landed, and puts back any script whose source has drifted, such as one an old Rojo serve
rewrote. That recheck touches script sources only, and creates and deletes nothing.

It maps the tree the way Rojo does:

- `.luau` scripts, with `init` scripts and the `.server` and `.client` suffixes.
- `*.model.json` files: their class, boolean, number and string properties and attributes, and
  their children. A model that sets any other value, such as a `Vector3` or a `NumberSequence`, is
  left to Studio: the plugin only reports when the place has no instance of its class there.
- `*.meta.json` files setting boolean, number and string properties and attributes, and an
  `init.meta.json` giving a folder with no `init` script its class.
- Plain `.json` files as ModuleScripts that decode the file's text with `HttpService:JSONDecode`.
  Rojo writes the data as a table literal, so the first sync after a Rojo serve rewrites them once.

A property or attribute removed from a `meta.json` or `model.json` goes back to the class default,
or is cleared, at the next sync.

Some commits wait for you to press **Sync now**: one that removes more than 20 instances, one that
changes the project file and removes any, and one that changes the class of an instance git owned
to or from a class Studio cannot convert in place. The first sync in a place waits too when it
would change the class of a script or folder, create an instance beside a same-named Studio
instance it cannot convert, or delete scripts git no longer has inside folders git owns outright.
A held sync's status and Output name each path, and every commit after a held one waits behind it.

Every sync is one undo step. Undo it and auto-sync pauses for everyone in the place until someone
presses **Sync now** or Redo. **Sync now** always syncs and resumes auto-sync for everyone.

In Team Create only one Studio syncs at a time; the others see the change replicate. The toolbar's
**Auto-sync** button turns it off on your computer only.

## Attributes

Agents read and drive it through attributes on `ServerStorage`. Each game keeps the names its own
agent rules document, with its prefix: `CloudSeekersSync`, `FloodedSync` or `EmblemTalesSync`.

| Attribute | Meaning |
| --- | --- |
| `<prefix>Commit` | The `main` commit the place matches |
| `<prefix>At` | When that sync ran (`os.time()`) |
| `<prefix>Changes` | The last sync's change list |
| `<prefix>Kept` | JSON list of instances git removed that were kept for their children |
| `<prefix>Seen_<UserId>` | That person's Studio last checked `main` with Auto-sync on (`os.time()`) |
| `<prefix>Status_<UserId>` | What that person's Studio is doing or waiting on |
| `<prefix>Lock` | Which Studio is syncing; ignored after two minutes |
| `<prefix>Request` | Set to `os.time()` to check `main` now |
| `<prefix>Paused` | `true` pauses auto-sync for everyone; Sync now clears it |

A `<prefix>Seen_*` older than a minute means that Studio has closed or turned Auto-sync off.

## Working on it

The toolchain is pinned in `rokit.toml`; `rokit install` fetches it. CI runs:

```bash
stylua --check .
selene studio-sync studio-sync-loader
lune run tests/run
rojo build default.project.json -o StudioSync.rbxm
```

A change to the mapping is checked against every game's project before it lands, from a checkout
of each game at its `main`:

```bash
lune run <StudioSync>/scripts/check-game-parity <StudioSync>/studio-sync default.project.json
```

It compares the plugin's map with `rojo sourcemap` and exits non-zero on any difference. Run it in
CloudSeekers (`default.project.json`), Flooded (`default.project.json hub.project.json`) and Emblem
Tales (`default.project.json title.project.json arena.project.json`).

Adding a place or a game is a row in `PLACES` (and `GAMES`) in `studio-sync/Config.luau`.
