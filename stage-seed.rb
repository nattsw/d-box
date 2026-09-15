#!/usr/bin/env ruby
# frozen_string_literal: true

# host-side: build a curated, path-rewritten seed dir for one box.
# the launcher mounts ONLY this dir into the box, so history/sessions/other
# projects' state are never reachable by the sandboxed agent.
#
# usage: stage-seed.rb <seed_out_dir>
#        DBOX_CODEX_CONFIG_ONLY=1 stage-seed.rb <config_out_file>

require "json"
require "fileutils"

SEED = ARGV[0] or abort "usage: stage-seed.rb <seed_out_dir>"

HOST_HOME = ENV["HOME"]
BOX_HOME = "/home/discourse"
AGENT_CONFIG_SKILLS = File.join(HOST_HOME, "workspace/agent-config/skills")
HOST_REPO = ENV["DBOX_REPO"] || File.join(HOST_HOME, "work/discourse/discourse")

# the box runs the agent with cwd /src, so claude keys project memory under "-src"
PROJECT_KEY = "-src"
HOST_MEMORY = File.join(HOST_HOME, ".claude/projects/-Users-natalie-work-discourse-discourse/memory")

# pin the Playwright MCP to the version whose chromium we baked into the image,
# so @latest can't drift ahead of the baked browser. Passed in via env.
PLAYWRIGHT_MCP = ENV["DBOX_PLAYWRIGHT_MCP"] # e.g. "@playwright/mcp@0.0.75"
PLAYWRIGHT_MCP_COMMAND = "/usr/local/bin/d-box-playwright-mcp"

# These MCPs belong to the macOS ChatGPT app or unrelated host projects. Their
# commands and OAuth state do not exist in a Linux Discourse box, so carrying an
# enabled host definition into the box can only produce startup warnings.
BOX_UNAVAILABLE_CODEX_MCPS = %w[node_repl computer-use cua_repl supabase vercel cats].freeze

def rewrite(str)
  # Rewrite the repo before the home directory, otherwise repo-local paths turn
  # into /home/discourse/work/... and never get a chance to become /src.
  str = str.gsub(HOST_REPO, "/src")
  str = str.gsub(HOST_HOME, BOX_HOME)
  if PLAYWRIGHT_MCP && !PLAYWRIGHT_MCP.empty?
    # Pin the @playwright/mcp version and force it through d-box's Chromium
    # wrapper. MCP's --browser option is a Chrome channel selector; "chromium"
    # is not a supported value there, so use --executable-path instead.
    # Headless and no-sandbox are also required inside the container. We inject
    # the args right after the package token (works for both JSON-array and
    # TOML-array forms, which both use "x", "y").
    str = str.gsub(/,\s*"--browser"\s*,\s*"[^"]*"/, "")
    injected_prefix = []
    injected_prefix << '"-y"' unless str.include?('"-y"')
    injected_args = []
    injected_args.concat(['"--executable-path"', '"/usr/local/bin/chromium"']) unless str.include?('"--executable-path"')
    injected_args << '"--headless"' unless str.include?('"--headless"')
    injected_args << '"--no-sandbox"' unless str.include?('"--no-sandbox"')
    str = str.gsub(%r{"@playwright/mcp(@[^"]*)?"}) do
      (injected_prefix + [%("#{PLAYWRIGHT_MCP}")] + injected_args).join(", ")
    end
    # also pin any non-quoted occurrences (e.g. in prose/help), just version
    str = str.gsub(%r{@playwright/mcp(@[^"'\s]+)?}, PLAYWRIGHT_MCP)
  end
  str
end

def copy(src, dst)
  return unless File.exist?(src)
  FileUtils.mkdir_p(File.dirname(dst))
  FileUtils.cp_r(src, dst)
end

def copy_resolved(src, dst)
  return unless File.exist?(src)
  FileUtils.mkdir_p(File.dirname(dst))
  FileUtils.rm_rf(dst)
  FileUtils.cp_r(File.realpath(src), dst)
end

def copy_skill_dirs(src_dir, dst_dir, skip: [])
  return [] unless Dir.exist?(src_dir)

  copied = []
  Dir.children(src_dir).sort.each do |name|
    next if skip.include?(name)

    src = File.join(src_dir, name)
    next unless File.directory?(src)

    copy_resolved(src, File.join(dst_dir, name))
    copied << name
  end
  copied
end

def newest_existing(paths)
  paths.compact.select { |path| File.exist?(path) }.max_by { |path| File.mtime(path) }
end

def write(path, content)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content)
end

def split_leading_root_toml(content)
  lines = content.lines
  first_table = lines.index { |line| line.match?(/^\s*\[/) } || lines.length
  [lines[0...first_table].join, lines[first_table..].join]
end

def root_toml_keys(content)
  root, = split_leading_root_toml(content)
  root.lines.map { |line| line[/^\s*([A-Za-z0-9_-]+)\s*=/, 1] }.compact
end

def prepend_root_toml(content, root)
  existing_keys = root_toml_keys(content)
  inserted = []

  root.lines.each do |line|
    key = line[/^\s*([A-Za-z0-9_-]+)\s*=/, 1]
    if key
      next if existing_keys.include?(key)

      existing_keys << key
    end
    inserted << line
  end

  return content unless inserted.any? { |line| line.match?(/^\s*[A-Za-z0-9_-]+\s*=/) }

  lines = content.lines
  first_table = lines.index { |line| line.match?(/^\s*\[/) } || lines.length
  lines.insert(first_table, "\n# --- discourse project root config (folded in from repo .codex/config.toml) ---\n", *inserted, "\n")
  lines.join
end

def toml_table_header(line)
  line[/\A\s*(\[[^\n#]+\])(?:\s*#.*)?\s*\z/, 1]
end

def toml_assignment_keys(lines)
  lines.map do |line|
    line[/\A\s*((?:[A-Za-z0-9_-]+|"(?:\\.|[^"])*"|'[^']*'))\s*=/, 1]
  end.compact
end

def merge_toml_tables(content, extra, label:)
  extra_lines = extra.lines
  table_starts = extra_lines.each_index.select { |i| toml_table_header(extra_lines[i]) }
  appended = []

  table_starts.each_with_index do |start, index|
    finish = table_starts[index + 1] || extra_lines.length
    section = extra_lines[start...finish]
    header = toml_table_header(section.first)
    content_lines = content.lines
    existing_start = content_lines.index { |line| toml_table_header(line) == header }

    # Array-of-table declarations are intentionally repeatable in TOML, so they
    # must remain separate even when both config files use the same header.
    unless existing_start && !header.start_with?("[[")
      appended.concat(section)
      next
    end

    existing_finish = ((existing_start + 1)...content_lines.length).find do |i|
      toml_table_header(content_lines[i])
    end || content_lines.length
    existing_keys = toml_assignment_keys(content_lines[(existing_start + 1)...existing_finish])
    added_keys = toml_assignment_keys(section.drop(1))
    duplicate_keys = existing_keys & added_keys
    unless duplicate_keys.empty?
      abort "stage-seed: #{label} repeats #{header} keys: #{duplicate_keys.join(', ')}"
    end

    content_lines.insert(
      existing_finish,
      "\n# --- #{label} (merged into #{header}) ---\n",
      *section.drop(1),
    )
    content = content_lines.join
  end

  if appended.any?
    content += "\n# --- #{label} ---\n"
    content += appended.join
  end

  content
end

def patch_playwright_mcp_value(value)
  changed = false

  case value
  when Hash
    if value["args"].is_a?(Array) &&
       value["args"].any? { |arg| arg.to_s.start_with?("@playwright/mcp") }
      value["command"] = PLAYWRIGHT_MCP_COMMAND
      value["args"] = []
      changed = true
    end

    value.each_value do |child|
      changed = true if patch_playwright_mcp_value(child)
    end
  when Array
    value.each do |child|
      changed = true if patch_playwright_mcp_value(child)
    end
  end

  changed
end

def patch_playwright_json_file(path)
  data = JSON.parse(File.read(path))
  return false unless patch_playwright_mcp_value(data)

  File.write(path, JSON.pretty_generate(data) + "\n")
  true
rescue JSON::ParserError
  false
end

def patch_playwright_toml(content)
  content.gsub(/(\[mcp_servers\.playwright\]\n)(?:command = .*\n)?(?:args = .*\n)?/) do
    "#{$1}command = #{PLAYWRIGHT_MCP_COMMAND.inspect}\nargs = []\n"
  end
end

def patch_github_mcp_url(content)
  content.gsub(
    'url = "https://api.githubcopilot.com/mcp"',
    'url = "https://api.githubcopilot.com/mcp/"',
  )
end

def set_mcp_server_enabled(content, name, enabled)
  table = Regexp.escape(name)
  pattern = /(^\[mcp_servers\.#{table}\][^\n]*\n)(.*?)(?=^\[|\z)/m

  content.sub(pattern) do |section|
    lines = section.lines
    header = lines.shift
    body = lines.join
    setting = "enabled = #{enabled}\n"

    if body.match?(/^\s*enabled\s*=/)
      body = body.sub(/^\s*enabled\s*=.*(?:\n|\z)/, setting)
    else
      body = setting + body
    end

    header + body
  end
end

def remove_root_toml_settings(content, keys)
  root, tables = split_leading_root_toml(content)
  pattern = /^\s*(?:#{keys.map { |key| Regexp.escape(key) }.join("|")})\s*=.*(?:\n|\z)/
  root.gsub(pattern, "") + tables
end

def set_root_toml_setting(content, key, value)
  root, tables = split_leading_root_toml(content)
  setting = "#{key} = #{value}\n"
  pattern = /^\s*#{Regexp.escape(key)}\s*=.*(?:\n|\z)/

  if root.match?(pattern)
    root = root.sub(pattern, setting)
  else
    root += setting
  end

  root + tables
end

def remove_toml_tables(content)
  dropping = false

  content.lines.map do |line|
    if (header = toml_table_header(line))
      dropping = yield(header)
    end
    line unless dropping
  end.compact.join
end

def set_toml_table_enabled(content, header, enabled)
  pattern = /(^#{Regexp.escape(header)}[^\n]*\n)(.*?)(?=^\[|\z)/m

  content.sub(pattern) do |section|
    lines = section.lines
    table_header = lines.shift
    body = lines.join
    setting = "enabled = #{enabled}\n"

    if body.match?(/^\s*enabled\s*=/)
      body = body.sub(/^\s*enabled\s*=.*(?:\n|\z)/, setting)
    else
      body = setting + body
    end

    table_header + body
  end
end

def sanitize_codex_container_config(content)
  # Permission profiles and app tool bridges are host concerns. Inside d-box,
  # Docker is the security boundary and Codex must not try to nest bwrap.
  content = remove_root_toml_settings(
    content,
    %w[approvals_reviewer default_permissions notify],
  )
  content = remove_toml_tables(content) do |header|
    header.start_with?("[permissions.")
  end
  content = set_root_toml_setting(content, "approval_policy", '"never"')
  content = set_root_toml_setting(content, "sandbox_mode", '"danger-full-access"')
  content = set_toml_table_enabled(
    content,
    '[plugins."codex-app-tools@openai-bundled"]',
    false,
  )
  set_toml_table_enabled(
    content,
    '[plugins."computer-use@openai-bundled"]',
    false,
  )
end

def build_codex_config
  codex_config = File.join(HOST_HOME, ".codex/config.toml")
  return unless File.exist?(codex_config)

  content = rewrite(File.read(codex_config))
  # The box always represents the Discourse repo, so fold its project-scoped
  # config into the box's global config at ~/.codex/config.toml.
  repo_codex = File.join(HOST_REPO, ".codex/config.toml")
  if File.exist?(repo_codex)
    repo_root, repo_tables = split_leading_root_toml(rewrite(File.read(repo_codex)))
    content = prepend_root_toml(content, repo_root)
    content = merge_toml_tables(
      content,
      repo_tables,
      label: "discourse project MCPs folded in from repo .codex/config.toml",
    )
  end

  content = patch_playwright_toml(content)
  content = patch_github_mcp_url(content)
  content = sanitize_codex_container_config(content)
  BOX_UNAVAILABLE_CODEX_MCPS.each do |name|
    content = set_mcp_server_enabled(content, name, false)
  end
  if ENV.fetch("GITHUB_PAT", "").empty?
    content = set_mcp_server_enabled(content, "github", false)
  end
  content
end

if ENV["DBOX_CODEX_CONFIG_ONLY"] == "1"
  content = build_codex_config
  abort "stage-seed: no host Codex config found" unless content

  write(SEED, content)
  File.chmod(0o600, SEED)
  exit
end

FileUtils.rm_rf(SEED)
FileUtils.mkdir_p(SEED)

claude_seed = File.join(SEED, ".claude")
codex_seed = File.join(SEED, ".codex")
agents_seed = File.join(SEED, ".agents")
mcps_seed = File.join(SEED, ".mcps")

# ---- claude: credentials, agents, plugins -------------------------------
# On macOS the LIVE oauth token lives in the Keychain; the ~/.claude/.credentials.json
# file is usually a stale leftover. Prefer the Keychain, fall back to the file.
def claude_credentials
  kc = `security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null`
  return kc unless kc.strip.empty?
  f = File.join(HOST_HOME, ".claude/.credentials.json")
  File.exist?(f) ? File.read(f) : nil
end
creds = claude_credentials
if creds
  write(File.join(claude_seed, ".credentials.json"), creds)
else
  warn "stage-seed: no claude credentials found (keychain or file) — box will require login"
end
copy(File.join(HOST_HOME, ".claude/agents"), File.join(claude_seed, "agents"))
copy(File.join(HOST_HOME, ".claude/plugins"), File.join(claude_seed, "plugins"))
claude_skills = []
claude_skills.concat(copy_skill_dirs(File.join(HOST_HOME, ".claude/skills"), File.join(claude_seed, "skills")))
claude_skills.concat(copy_skill_dirs(AGENT_CONFIG_SKILLS, File.join(claude_seed, "skills")))
claude_skills.uniq!

# ---- claude: settings.json (drop mac-only peon-ping hooks + host paths) --
settings_path = File.join(HOST_HOME, ".claude/settings.json")
if File.exist?(settings_path)
  settings = JSON.parse(File.read(settings_path))
  settings.delete("hooks")        # all hooks are peon-ping audio (afplay) — useless + 10s timeouts in a linux box
  settings.delete("permissions")  # mac JetBrains scratch paths — irrelevant in the box
  write(File.join(claude_seed, "settings.json"), rewrite(JSON.pretty_generate(settings)))
end

# ---- claude: curated ~/.claude.json (mcpServers + flags only) ------------
claude_json_path = File.join(HOST_HOME, ".claude.json")
mcp_servers = {}
if File.exist?(claude_json_path)
  host = JSON.parse(File.read(claude_json_path))
  mcp_servers = host["mcpServers"] || {}
  # promote the discourse-project-scoped figma server to global so it loads at /src
  project = (host["projects"] || {})[File.join(HOST_HOME, "work/discourse/discourse")] || {}
  (project["mcpServers"] || {}).each { |k, v| mcp_servers[k] ||= v }
end
curated = {
  "mcpServers" => mcp_servers,
  "hasCompletedOnboarding" => true,
  "projects" => {
    "/src" => { "hasTrustDialogAccepted" => true, "hasCompletedProjectOnboarding" => true },
  },
}
write(File.join(SEED, ".claude.json"), rewrite(JSON.pretty_generate(curated)))

# ---- mcp profiles --------------------------------------------------------
mcps_dir = File.join(HOST_HOME, ".mcps")
if Dir.exist?(mcps_dir)
  FileUtils.mkdir_p(mcps_seed)
  Dir.glob(File.join(mcps_dir, "*.json")).each do |f|
    write(File.join(mcps_seed, File.basename(f)), rewrite(File.read(f)))
  end
end

# ---- codex: auth, config (rewritten), rules, skills ----------------------
codex_auth = newest_existing([
  ENV["DBOX_CODEX_AUTH_FILE"],
  File.join(HOST_REPO, ".codex/auth.json"),
  File.join(HOST_HOME, ".codex/auth.json"),
])
if codex_auth
  copy(codex_auth, File.join(codex_seed, "auth.json"))
  File.chmod(0o600, File.join(codex_seed, "auth.json"))
else
  warn "stage-seed: no codex auth found (repo .codex/auth.json or ~/.codex/auth.json) — box will require login"
end
copy(File.join(HOST_HOME, ".codex/rules"), File.join(codex_seed, "rules"))
copy(File.join(HOST_HOME, ".codex/skills/.system"), File.join(codex_seed, "skills/.system"))
copy(File.join(HOST_HOME, ".codex/.tmp/marketplaces"), File.join(codex_seed, ".tmp/marketplaces"))
codex_skills = File.join(HOST_HOME, ".agents/skills")
codex_machine_skills = []
codex_machine_skills.concat(copy_skill_dirs(codex_skills, File.join(agents_seed, "skills")))
codex_machine_skills.concat(copy_skill_dirs(AGENT_CONFIG_SKILLS, File.join(agents_seed, "skills")))
codex_machine_skills.uniq!
content = build_codex_config
if content
  path = File.join(codex_seed, "config.toml")
  write(path, content)
  File.chmod(0o600, path)
end

# ---- plugins: rewrite host paths + pinned MCP packages in copied config ----
# Some plugin MCP definitions live in hidden files like `.mcp.json`, so include
# dotfiles here. This keeps plugin-provided Playwright MCPs from drifting to
# @latest while the baked browser remains pinned.
[
  File.join(claude_seed, "plugins"),
  File.join(codex_seed, ".tmp/marketplaces"),
].each do |root|
  Dir.glob(File.join(root, "**", "{*,.*}.json"), File::FNM_DOTMATCH).each do |f|
    next unless File.file?(f)

    content = File.read(f)
    rewritten = rewrite(content)
    File.write(f, rewritten) if rewritten != content
    patch_playwright_json_file(f)
  end
end

# ---- shared memory under the /src project key ----------------------------
# copied verbatim — memory notes are prose that may legitimately mention host
# paths, so we do NOT rewrite their contents.
if Dir.exist?(HOST_MEMORY)
  copy(HOST_MEMORY, File.join(claude_seed, "projects", PROJECT_KEY, "memory"))
end

puts "staged seed -> #{SEED}"
puts "  mcp servers: #{mcp_servers.keys.join(", ")}"
puts "  claude skills: #{claude_skills.join(", ")}" if claude_skills.any?
puts "  codex machine skills: #{codex_machine_skills.join(", ")}" if codex_machine_skills.any?
