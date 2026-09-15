# d-box

Disposable Claude Code and Codex environments for Discourse development. Each box
has a Docker container, a git worktree and branch, and its own Postgres and Redis.
You can edit the worktree on the host while agents and the development server run
inside the container.

The launcher runs agents with approval checks disabled. Boxes share the main
repository's git metadata, receive selected host credentials, and have network
access. See [Shared access and stored data](#shared-access-and-stored-data) for
what persists and what agents can reach.

## Setup

This setup assumes **macOS with OrbStack**. The launcher uses OrbStack's
`<container>.orb.local` addresses, macOS Keychain and clipboard tools, and launchd
for the optional Tailscale bridge.

Before starting, you need:

- OrbStack running, with the Docker CLI available.
- Git, Bash, Ruby, and `jq` on the host.
- A local Discourse checkout with the branch you want to build from.
- Host logins for the agents you use. Codex config is read from
  `~/.codex/config.toml` and the Discourse checkout's `.codex/config.toml`.
- A key loaded in the host SSH agent if you use GitHub over SSH. The default key
  selector matches a public-key comment containing `id_rsa.discourse`.

From this directory:

```bash
cp .env.example .env
# Edit .env: check DBOX_REPO, DBOX_IMAGE, and tailnet settings.
./d-box build
./d-box new my-feature
./d-box url my-feature
./d-box claude my-feature
# Or: ./d-box codex my-feature
```

Keep `DBOX_IMAGE` set in `.env`; the build command reads it directly. The example
configuration uses `~/work/discourse/discourse` and builds from its local `main`
branch. Fetch or update that branch yourself before building if needed.

`build` installs the agent CLIs and pinned MCP packages, then bakes Discourse
sources, dependencies, browsers, and migrated development/test databases into the
image. `new` creates the worktree, copies agent configuration, installs dependency
changes, runs plugin-aware migrations, and starts `bin/dev` in the background.
Asset compilation may still be running when `new` prints the URL.

### Configuration

The launcher sources `.env` as shell code on each invocation. Start
with [.env.example](.env.example); values there override exported shell variables.

| Variable | Default or purpose |
| --- | --- |
| `DBOX_REPO` | Main Discourse checkout; defaults to `~/work/discourse/discourse`. |
| `DBOX_BASE_BRANCH` | Local branch used by `build` and as the default base for `new`; `main`. |
| `DBOX_BASE` | Docker parent image; `discourse/discourse_dev:release`. |
| `DBOX_IMAGE` | Built image tag; set to `d-box:latest` in the example. |
| `DBOX_ADMIN_USERNAME`, `DBOX_ADMIN_EMAIL`, `DBOX_ADMIN_PASSWORD` | Optional development admin. An empty password skips creation. |
| `DBOX_EXPOSE` | `1` enables tailnet exposure when Tailscale is available; `0` disables it. |
| `DBOX_TS_BASE_PORT` | First tailnet port to allocate; `3001`. Port `3000` is reserved. |
| `DBOX_GITHUB_SSH_KEY` | Substring of the forwarded agent key's comment; `id_rsa.discourse`. |
| `DBOX_SSH_SOCK` | Host agent bridge; `/run/host-services/ssh-auth.sock`. |
| `GITHUB_PAT` | Allows the configured remote GitHub MCP in Codex. Forwarded to the launched process. |
| `DBOX_COPY_MANIFEST` | Files to copy into new boxes; this repository's `copy-files`. |
| `DBOX_DISCOURSE_MCP` | Package installed at build time; `@discourse/mcp@0.1.10`. |
| `DBOX_PLAYWRIGHT_MCP` | Package installed at build time; `@playwright/mcp@0.0.75`. |
| `DBOX_PATCH_TRIAGE_MCP` | Optional gem source to bake into the image; `~/work/discourse/patch-triage/mcp`. |

Tailnet URLs currently use the hardcoded hostname
`steakbookpro.great-flops.ts.net` in both `d-box` and `entrypoint.rb`. On another
machine, set `DBOX_EXPOSE=0` or adapt those values before using tailnet access.

### Shell shortcut and completion

To use `db` from other directories, add this to `~/.zshrc`, adjusting the path if
needed. Load completion after `compinit` or Oh My Zsh:

```zsh
alias db="$HOME/work/discourse/d-box/d-box"
source "$HOME/work/discourse/d-box/completion.zsh"
```

The examples below use `./d-box` from this directory; `db` works the same way.

## Daily use

### Create and select boxes

```bash
./d-box new my-feature                  # New branch from DBOX_BASE_BRANCH
./d-box new another-feature my-feature  # New branch from a different local base
./d-box new test-only --no-serve         # Initialize without starting bin/dev
./d-box use my-feature                  # Select the default box
./d-box use                             # Show the current selection
./d-box list                            # List boxes, URLs, and worktrees
```

If the branch already exists, `new` checks it out instead of creating it. Git's
usual restriction applies: a branch cannot already be checked out in another
worktree. Box names replace characters outside letters, digits, `_`, `.`, and `-`
with `-`, so `fix/example` becomes `fix-example`. Choose names with distinct results.

The newest box becomes the default. Most commands accept an optional box name and
otherwise use that selection. `update-codex` also checks the enclosing
`worktrees/<box>/` directory before falling back to the selected box.

### Agents, shell, and Rails

```bash
./d-box claude my-feature
./d-box claude my-feature -c             # Continue the Claude session
./d-box codex my-feature
./d-box shell my-feature                 # Bash as discourse, in /src
./d-box rails my-feature                 # Rails console
./d-box rails my-feature 'puts User.count'
./d-box admin my-feature                 # Apply admin settings from .env
```

Additional arguments after the box name are passed to the agent CLI. Claude runs
with `--dangerously-skip-permissions`; Codex runs with
`--dangerously-bypass-approvals-and-sandbox`.

To run Ruby after initialization, use
`./d-box new my-feature -rc 'puts User.count'`. Set the three `DBOX_ADMIN_*`
variables to create a development admin during `new`, or refresh it with `admin`.
The launcher prints a `/session/<username>/become` login link when configured.

To attach a clipboard image:

```bash
./d-box imgpaste my-feature
./d-box codex my-feature -i "$(./d-box imgpaste my-feature)"
```

`imgpaste` saves a PNG under `worktrees/<box>/tmp/` and prints its container path,
`/src/tmp/img-<timestamp>.png`.

### Development server and container lifecycle

| Command | Behavior |
| --- | --- |
| `./d-box up [box]` | Start the container if needed, start the background server, wait for HTTP, and enable automatic serving after reboot. |
| `./d-box down [box]` | Stop the server and disable automatic serving; leave the container running. |
| `./d-box restart [box]` | Restart the server and wait for HTTP. Requires a running container. |
| `./d-box stop [box]` | Stop the container while preserving its data and previous serving preference. |
| `./d-box start [box]` | Start the container; resume the server if serving was enabled. |
| `./d-box serve [box]` | Run `bin/dev` in the foreground. Ctrl-C stops that server. |
| `./d-box logs [box]` | Tail the last 100 lines of `/tmp/dev.log` and follow new output. |
| `./d-box url [box]` | Print the app URL and attempt to restore tailnet exposure if enabled. |

Run `down` before `serve` if the background server is already running.

Containers use Docker's `unless-stopped` restart policy, and runit supervises the
dev server. A running box returns when OrbStack and Docker recover after a host
reboot. An explicit `stop` keeps the container stopped across reboots; `down`
keeps automatic serving disabled until `up` or `restart` enables it again.

### URLs

The canonical app URL is `http://<slug>.orb.local:3000`. Rails, Discourse's hostname,
`DBOX_APP_URL`, and generated agent context use this address.

When enabled, Tailscale adds `http://steakbookpro.great-flops.ts.net:<port>` for
other devices on the tailnet. Ports start at `3001`, skip occupied or assigned
ports, and persist in `state/<slug>/tailnet-port`. Old assignments using `3000`
are replaced on the next allocation.

Docker publishes no host ports. A launchd-managed bridge listens on loopback at
the allocated port and forwards to the OrbStack address; `tailscale serve` uses
that bridge. Its log is `state/<slug>/tailnet-proxy.log`.

## Updates and recovery

```bash
./d-box auth                       # Refresh both agents' credentials in all seeds and running boxes
./d-box config                     # Refresh Codex config in all seeds and running boxes
./d-box update-codex my-feature     # Update Codex in this box
./d-box build                      # Rebuild the image for future boxes
./d-box repair my-feature          # Recreate a container while preserving its data
./d-box repair my-feature --no-serve
```

`build` leaves existing boxes unchanged. If a snapshot is selected as the base,
it also refreshes agent CLIs and pinned MCP packages in that snapshot while
preserving its database. `update-codex` changes only the selected box.

`repair` commits the existing container and recreates it with current mount
settings. It preserves the database, worktree, and `node_modules` volume, refreshes
auth/config, and starts the server unless `--no-serve` is supplied. Use it for a
container that cannot start because of a stale mount.

For a server startup failure, check `logs`, then use `restart` after addressing
the error. For expired agent credentials, log in again on the host and reattach,
or run `auth` to refresh every box.

### Authentication and configuration seeding

[stage-seed.rb](stage-seed.rb) copies selected host configuration to
`state/<slug>/seed/`, rewriting host home paths to `/home/discourse` and repository
paths to `/src`. That directory is mounted read-only at `/seed`;
[entrypoint.rb](entrypoint.rb) copies it into the container's home on startup.

- Claude credentials come from the macOS `Claude Code-credentials` Keychain item,
  falling back to `~/.claude/.credentials.json`. The credential blob includes MCP
  OAuth tokens. `new`, `repair`, `claude`, and `auth` refresh it; the host mirror is
  `state/.claude-credentials.json`.
- Codex uses the newest token file from `$DBOX_REPO/.codex/auth.json` and
  `~/.codex/auth.json`, mirroring it into the repository-local path. `new`, `repair`,
  `codex`, and `auth` refresh it.
- Codex config combines host and Discourse project config. Host permission
  profiles, notifications, and app bridges are removed or disabled for the box.
  Unavailable host MCPs are disabled, as is the GitHub MCP when `GITHUB_PAT` is
  absent. `new`, `repair`, `codex`, and `config` refresh this configuration.
- Seeds include Claude agents and plugins, settings with hooks and host
  permissions removed, MCP profile JSON files, Codex rules and system skills,
  and available skills from `~/.claude/skills`, `~/.agents/skills`, and
  `~/workspace/agent-config/skills`. Project skills arrive through the worktree.
- Shared Claude memory is copied under the `/src` project key and linked for
  Codex. Its source path in `stage-seed.rb` is specific to Natalie's checkout;
  adapt it if using another layout.

The [copy-files](copy-files) manifest adds live host files during `new`; the
provided entry copies `AI-AGENTS.md` from the main Discourse checkout when present.
Relative sources resolve against `DBOX_REPO`. Explicit destinations can point to
`/src/...` or the container's home, for example:

```text
config/local.yml
~/dotfiles/.vimrc -> ~/.vimrc
```

### Browser tools and tests

The image includes Chromium under `/ms-playwright`, exposed through
`/usr/local/bin/chromium`. Containers set QUnit/Testem defaults for headless browser
tests. Seeded Playwright MCP configurations use
`/usr/local/bin/d-box-playwright-mcp`, which launches the pinned MCP with the baked
Chromium and `--isolated --headless --no-sandbox`.

Run Discourse tests from `./d-box shell my-feature`, where the working directory
is `/src`. The launcher's standalone port-allocation regression check runs on the
host without starting containers:

```bash
bash tests/tailnet-port.sh
```

## Snapshots

```bash
./d-box snapshot my-feature prepared    # Save this box as snapshot "prepared"
./d-box snapshots                      # List snapshots and the active base
./d-box base prepared                  # Use it for future boxes
./d-box new next-feature
./d-box base default                   # Return to the normal built image
./d-box rmsnap prepared                # Delete the saved snapshot
```

Snapshots capture the container filesystem, including database state and system
changes. Bind-mounted worktrees, seeds, and the `node_modules` volume are excluded;
new boxes receive their own mounts. With one argument, `snapshot prepared` names
a snapshot of the current box; use two arguments to select both box and name.

Snapshots also capture credentials already copied into the container's home.
Treat them as local images containing secrets.

## Shared access and stored data

| Location | Contents |
| --- | --- |
| `worktrees/<slug>/` | Host worktree, mounted read-write at `/src`. |
| Main checkout's common `.git` directory | Mounted read-write at its original absolute path so worktree git operations work. |
| `state/<slug>/` | Seed configuration and credentials, tailnet assignment, and bridge files. |
| `dbox-<slug>-node_modules` Docker volume | Per-box JavaScript dependencies and pnpm store. |
| Container filesystem | Databases, agent sessions, installed gems, and other runtime changes. |

Commits made in a box are visible from the host through the shared git object
store. Run worktree administration commands on the host. Agents can also change
shared branches and git history, use the forwarded SSH agent, and call external
services with copied tokens. Development servers enable anonymous impersonation
for the local login workflow.

Host session/history directories are not seeded, but selected credentials and
MCP profiles are. The optional `patch-triage-mcp` gem and host-local MCP services
may need additional setup; `localhost` inside a container refers to that container.

## Remove a box

```bash
./d-box rm my-feature
./d-box rm my-feature --delete-branch
```

`rm` force-removes the container, its dependency volume, worktree, seed, and tailnet
bridge. **Uncommitted work and the box's database are deleted without a prompt.**
The branch and its commits remain unless `--delete-branch` is supplied, which
force-deletes the branch too. Pass the original branch name when deleting a branch
such as `fix/example`. Saved snapshots are removed separately with `rmsnap`.
