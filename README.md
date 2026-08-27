# d-box

Disposable **Claude Code + Codex** sandboxes for the Discourse repo. Each box is one
Docker container = one git worktree = one branch, with its own Postgres/Redis. Run
agents in YOLO mode without letting them touch anything outside the box.

## Setup

```bash
cp .env.example .env      # optional — defaults assume ~/work/discourse/discourse
./d-box build             # update Claude/Codex CLIs; bake deps, browsers, migrated DBs
```

## Use

```bash
./d-box new my-feature            # worktree + box on branch my-feature (off main)
./d-box claude my-feature         # attach to YOLO claude inside the box
./d-box codex  my-feature         # attach to full-bypass codex inside the box
./d-box imgpaste my-feature       # save clipboard image to /src/tmp/img-<timestamp>.png
./d-box shell  my-feature         # bash prompt inside the box
./d-box list                      # list boxes + worktrees
./d-box rm     my-feature         # tear down container + volumes + worktree + seed
./d-box rm     my-feature --delete-branch
./d-box auth                      # push host claude+codex auth to all boxes
```

Attach the current clipboard image when launching Codex:

```bash
./d-box codex my-feature -i "$(./d-box imgpaste my-feature)"
```

`new` is the slow step (bundle + pnpm + db migrate). After that, `claude`/`codex`/`shell`
attach instantly. Run several boxes at once for parallel tasks — they don't collide.

## How it works

- **Command contracts**:
  - `d-box build` owns the image: install/update the agent CLIs and pinned MCPs,
    bake Discourse dependencies, browsers, and migrated development/test DBs, then
    refresh the active base image if one is selected. It does not mutate running
    boxes or refresh agent auth in existing seeds.
  - `d-box new` owns box creation/initialization: create or reuse the worktree,
    stage the seed, create/start the container, sync auth for that box, patch MCP
    config, install dependency deltas, migrate DBs, create the optional admin user,
    write agent URL context, optionally start `bin/dev`, and expose the box.
  - `d-box restart` owns only the dev server for an already-running box: stop
    `bin/dev`/Pitchfork/Rolldown, refresh URL context, start `bin/dev` in the
    background, wait for HTTP, and print URLs. Container start/stop remains the
    job of `d-box start` and `d-box stop`.
    Running boxes use Docker's `unless-stopped` restart policy, and `bin/dev` is
    supervised by runit, so boxes which were being served return automatically
    after OrbStack and Docker recover from a host reboot. `d-box down` records an
    explicit opt-out; `d-box up` turns reboot auto-serving back on.
    Every box has exactly two supported URLs: `http://<slug>.orb.local:3000`
    locally and `http://steakbookpro.great-flops.ts.net:<incremental-port>` on
    the tailnet. A launchd-supervised host bridge uses that same incremental
    port internally, so Docker publishes no host ports and d-box does not
    introduce a third URL or a separate backend-port range.
- **Image** (`Dockerfile`): base `discourse/discourse_dev` + `claude`, `codex`,
  `@discourse/mcp`, pinned `@playwright/mcp`, `gh`, `jq`, playwright chromium.
  `ENTRYPOINT` seeds config then `exec`s `/sbin/boot`.
- **Browser tests**: boxes expose `/usr/local/bin/chromium` backed by the baked
  Playwright Chromium and set QUnit/Testem defaults for container-safe headless runs.
  Claude/Codex Playwright MCP configs point at `/usr/local/bin/d-box-playwright-mcp`,
  a wrapper that always runs the pinned MCP against `/usr/local/bin/chromium` with
  `--isolated --headless --no-sandbox`.
- **Config seeding**: `stage-seed.rb` runs on the **host** and copies only a curated
  subset of your `~/.claude` / `~/.codex` / `~/.agents` / `~/.mcps` into `state/<slug>/seed/`,
  rewriting `$HOME` → `/home/discourse`. The launcher mounts only that dir read-only at
  `/seed`. Your history, sessions, and other projects' state are never exposed.
  `entrypoint.rb` applies the seed into the box's home.
- **Claude auth refresh**: `new`, `repair`, `claude`, and `auth` copy the host's live
  Claude credentials into box seeds and running boxes. On macOS the live token lives
  in the Keychain (`Claude Code-credentials`), so that's read first and
  `~/.claude/.credentials.json` is only a fallback — the file on disk is usually
  stale. The blob carries both the Claude oauth token and the MCP oauth tokens
  (`mcpOAuth`), so connector logins ride along. It's mirrored to the gitignored
  `state/.claude-credentials.json` and never baked into images. Log in on the host,
  then `d-box claude <box>` picks it up on attach; `d-box auth` pushes it to every
  box at once.
- **Codex auth refresh**: `new`, `repair`, and `codex` copy the newest host
  Codex token from `$DBOX_REPO/.codex/auth.json` or `~/.codex/auth.json`
  into box seeds and running boxes. The host token is mirrored into the repo-local
  `.codex/auth.json` path, which is ignored by git. Tokens are not baked into images.
- **Git**: the worktree's `.git` points at the main repo's `.git` by absolute host path,
  so the launcher bind-mounts the shared `.git` at its identical path. Commits land in
  the shared object store (visible from the host). Run `git worktree` admin on the host.
  GitHub SSH uses the forwarded host agent, pinned by default to the agent key whose
  public-key comment contains `id_rsa.discourse`. Override with `DBOX_GITHUB_SSH_KEY`
  in `.env` if your GitHub key has a different comment.
- **What's replicated**: Claude/Codex auth, settings (peon-ping hooks stripped),
  `code-reviewer` agent, plugins (ruby-lsp, figma, skill-codex), all MCP servers,
  machine-level Claude skills plus Codex user skills from `~/workspace/agent-config/skills`, and
  your shared memory (under the `/src` project key). Discourse project skills come
  in via the worktree (`/src/.skills`), not the seed.

## Caveats

- Real API tokens (MCP profiles, netlify, patch-triage) are copied into the box and the
  network is open — rotate anything you wouldn't want a runaway agent to reach.
- `patch-triage-mcp` (a Ruby gem) and the `d-local` MCP (`localhost:4200` = host) are
  best-effort and may not work in the box without extra setup.
- The shared `.git` is mounted read-write, so an agent could rewrite history; changes are
  reviewable from the host.
