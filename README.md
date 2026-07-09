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
./d-box shell  my-feature         # bash prompt inside the box
./d-box list                      # list boxes + worktrees
./d-box rm     my-feature         # tear down container + volumes + worktree + seed
./d-box rm     my-feature --delete-branch
```

`new` is the slow step (bundle + pnpm + db migrate). After that, `claude`/`codex`/`shell`
attach instantly. Run several boxes at once for parallel tasks — they don't collide.

## How it works

- **Image** (`Dockerfile`): base `discourse/discourse_dev` + `claude`, `codex`,
  `@discourse/mcp`, `gh`, `jq`, playwright chromium. `ENTRYPOINT` seeds config then
  `exec`s `/sbin/boot`.
- **Browser tests**: boxes expose `/usr/local/bin/chromium` backed by the baked
  Playwright Chromium and set QUnit/Testem defaults for container-safe headless runs.
- **Config seeding**: `stage-seed.rb` runs on the **host** and copies only a curated
  subset of your `~/.claude` / `~/.codex` / `~/.agents` / `~/.mcps` into `state/<slug>/seed/`,
  rewriting `$HOME` → `/home/discourse`. The launcher mounts only that dir read-only at
  `/seed`. Your history, sessions, and other projects' state are never exposed.
  `entrypoint.rb` applies the seed into the box's home.
- **Codex auth refresh**: `new`, `build`, `repair`, and `codex` copy the newest host
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
