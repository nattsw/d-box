#!/usr/bin/env ruby
# frozen_string_literal: true

# image ENTRYPOINT (runs as root). applies the read-only staged seed into the
# discourse user's home, then hands off to the base image's service supervisor.

require "fileutils"
require "socket"

BOX_HOME = "/home/discourse"
CHROMIUM_WRAPPER = "/usr/local/bin/chromium"
PLAYWRIGHT_MCP_WRAPPER = "/usr/local/bin/d-box-playwright-mcp"
DEV_SERVICE_DIR = "/etc/service/d-box-dev"
AUTO_SERVE_MARKER = "/var/lib/d-box/auto-serve"
BOX_OWNER_FILE = "/var/lib/d-box/owner"

def container_generation
  # Legacy boxes have no generation env, so their stable hostname is the
  # migration key. Newly created/repaired boxes receive a unique immutable key.
  ENV.fetch("DBOX_CONTAINER_GENERATION", Socket.gethostname)
end

def install_dev_service
  FileUtils.mkdir_p(DEV_SERVICE_DIR)
  FileUtils.mkdir_p(File.dirname(AUTO_SERVE_MARKER))
  File.write(
    "#{DEV_SERVICE_DIR}/run",
    <<~BASH,
      #!/usr/bin/env bash
      set -euo pipefail

      cd /src
      export HOME=/home/discourse
      export UNICORN_BIND_ALL=true
      export RAILS_DEVELOPMENT_HOSTS="$(hostname).orb.local,steakbookpro.great-flops.ts.net"
      export DISCOURSE_HOSTNAME="$(hostname).orb.local"
      export DBOX_APP_URL="http://$(hostname).orb.local:3000"
      export DISCOURSE_DEV_ALLOW_ANON_TO_IMPERSONATE=1

      # runsv starts services concurrently. Do not let Rails race the database
      # services during a container/host reboot.
      until pg_isready -q && redis-cli ping >/dev/null 2>&1; do
        sleep 1
      done

      exec chpst -u discourse:discourse bash -lc 'exec bin/dev' >> /tmp/dev.log 2>&1
    BASH
  )
  File.chmod(0o755, "#{DEV_SERVICE_DIR}/run")

  # runit reads this file when runsvdir starts. `d-box up` removes it and records
  # the desired state in AUTO_SERVE_MARKER; `d-box down` does the inverse.
  down_file = "#{DEV_SERVICE_DIR}/down"
  if File.exist?(AUTO_SERVE_MARKER)
    FileUtils.rm_f(down_file)
  else
    FileUtils.touch(down_file)
  end
end

# Existing containers bind-mount this file, so the launcher can install the new
# runit service in-place without rebuilding or recreating the box.
if ARGV == ["--install-dev-service"]
  FileUtils.mkdir_p(File.dirname(BOX_OWNER_FILE))
  File.write(BOX_OWNER_FILE, "#{container_generation}\n")
  install_dev_service
  exit
end

File.write(
  CHROMIUM_WRAPPER,
  <<~BASH,
    #!/usr/bin/env bash
    set -euo pipefail

    browser="$(
      find /ms-playwright -path '*/chrome-linux/chrome' -type f 2>/dev/null |
        sort -V |
        tail -1
    )"

    if [ -z "$browser" ]; then
      echo "d-box: Playwright Chromium is not installed under /ms-playwright" >&2
      exit 127
    fi

    exec "$browser" "$@"
  BASH
)
File.chmod(0o755, CHROMIUM_WRAPPER)

File.write(
  PLAYWRIGHT_MCP_WRAPPER,
  <<~BASH,
    #!/usr/bin/env bash
    set -euo pipefail

    export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/ms-playwright}"
    export CHROME_BIN="${CHROME_BIN:-/usr/local/bin/chromium}"
    pkg="${DBOX_PLAYWRIGHT_MCP:-@playwright/mcp@0.0.75}"

    if command -v playwright-mcp >/dev/null 2>&1; then
      exec playwright-mcp --executable-path "$CHROME_BIN" --isolated --headless --no-sandbox "$@"
    fi

    exec npx -y "$pkg" --executable-path "$CHROME_BIN" --isolated --headless --no-sandbox "$@"
  BASH
)
File.chmod(0o755, PLAYWRIGHT_MCP_WRAPPER)

if Dir.exist?("/seed")
  # copy the curated config tree (.claude, .claude.json, .mcps, .codex, .agents) into HOME
  system("cp", "-a", "/seed/.", "#{BOX_HOME}/")
  # chown only the seeded items — NOT all of HOME (avoids re-chowning baked ~/.bundle gems)
  %w[.claude .claude.json .mcps .codex .agents].each do |n|
    p = "#{BOX_HOME}/#{n}"
    system("chown", "-R", "discourse:discourse", p) if File.exist?(p)
  end

  # tighten secrets
  [
    "#{BOX_HOME}/.claude/.credentials.json",
    "#{BOX_HOME}/.codex/auth.json",
  ].each { |f| File.chmod(0o600, f) if File.exist?(f) }

  # named-volume mounts (node_modules) come up root-owned — hand them to discourse
  ["/src/node_modules"].each do |d|
    system("chown", "discourse:discourse", d) if Dir.exist?(d)
  end

  # keep pnpm's content store ON the node_modules volume so it hardlinks instead
  # of copying across filesystems (the bind mount vs the volume) — avoids ENOMEM
  npmrc = "#{BOX_HOME}/.npmrc"
  store_line = "store-dir=/src/node_modules/.pnpm-store\n"
  existing = File.exist?(npmrc) ? File.read(npmrc) : ""
  unless existing.include?("store-dir=")
    File.write(npmrc, existing + store_line)
    system("chown", "discourse:discourse", npmrc)
  end

  # recreate the codex -> claude memory symlink (codex shares claude's memory)
  memory = "#{BOX_HOME}/.claude/projects/-src/memory"
  link = "#{BOX_HOME}/.codex/memories/discourse-claude-memory"
  if Dir.exist?(memory)
    FileUtils.mkdir_p(File.dirname(link))
    FileUtils.rm_f(link)
    File.symlink(memory, link)
    system("chown", "-h", "discourse:discourse", link)
  end
end

# SSH agent forwarding: the forwarded socket comes in root-owned, so make it usable
# by the discourse user; and auto-accept new host keys so git-over-ssh never prompts.
if File.exist?("/ssh-agent")
  system("chmod", "0666", "/ssh-agent")
end
ssh_dir = "#{BOX_HOME}/.ssh"
FileUtils.mkdir_p(ssh_dir)
cfg = "#{ssh_dir}/config"

github_key = ENV.fetch("DBOX_GITHUB_SSH_KEY", "id_rsa.discourse").strip
d_box_begin = "# BEGIN d-box managed\n"
d_box_end = "# END d-box managed\n"
d_box_config = +""

unless github_key.empty?
  pubkeys = `su discourse -c 'SSH_AUTH_SOCK=/ssh-agent ssh-add -L' 2>/dev/null`
  github_pubkey =
    pubkeys.lines.find do |line|
      _type, _body, comment = line.chomp.split(/\s+/, 3)
      comment&.include?(github_key)
    end

  if github_pubkey
    github_pubkey_file = "#{ssh_dir}/d-box-github.pub"
    File.write(github_pubkey_file, github_pubkey)
    File.chmod(0o600, github_pubkey_file)

    d_box_config << <<~SSH
      Host github.com
        HostName github.com
        User git
        IdentityFile #{github_pubkey_file}
        IdentitiesOnly yes

    SSH
  end
end

d_box_config << <<~SSH
  Host *
    StrictHostKeyChecking accept-new
SSH

existing_config = File.exist?(cfg) ? File.read(cfg) : ""
existing_config = existing_config.gsub(/# BEGIN d-box managed\n.*?# END d-box managed\n?/m, "")
File.write(cfg, "#{d_box_begin}#{d_box_config}#{d_box_end}#{existing_config}")

system("chown", "-R", "discourse:discourse", ssh_dir)
File.chmod(0o700, ssh_dir)
File.chmod(0o600, cfg) if File.exist?(cfg)

# the home DIR itself must be discourse-owned so the user can create ~/.gitconfig
# etc. Done AFTER the cp above, because `cp -a /seed/.` copies the seed dir's
# ownership onto HOME and would otherwise revert it to root. Non-recursive, so it
# does NOT touch the baked ~/.bundle gems inside.
system("chown", "discourse:discourse", BOX_HOME)

# A snapshot may contain the source box's auto-serve marker. A different
# container generation means this is a newly-created/repaired box, not a reboot,
# so start disabled until the launcher finishes initialization and explicitly
# enables it.
current_owner = container_generation
previous_owner = File.exist?(BOX_OWNER_FILE) ? File.read(BOX_OWNER_FILE).strip : ""
if previous_owner != current_owner
  FileUtils.rm_f(AUTO_SERVE_MARKER)
  FileUtils.mkdir_p(File.dirname(BOX_OWNER_FILE))
  File.write(BOX_OWNER_FILE, "#{current_owner}\n")
end

install_dev_service

# keep the container alive + boot postgres/redis/etc (replaces PID 1)
exec "/sbin/boot"
