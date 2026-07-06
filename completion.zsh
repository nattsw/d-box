# d-box zsh completion — source this from ~/.zshrc (AFTER compinit / oh-my-zsh):
#   source ~/work/discourse/d-box/completion.zsh

_d-box() {
  local -a cmds
  cmds=(
    'build:update Claude/Codex CLIs; bake gems, pnpm deps, browsers, and migrated DBs for faster new boxes'
    'new:create a box + start its dev server'
    'use:set (or show) the default box'
    'snapshot:save a box state (DB + system) as a reusable image'
    'snapshots:list snapshots + the active base'
    'base:make new boxes start from a snapshot (or reset)'
    'rmsnap:delete a snapshot'
    'claude:launch YOLO claude in the box'
    'codex:launch full-bypass codex in the box'
    'shell:bash prompt in the box'
    'rails:rails console (or run ruby in the rails env)'
    'up:start the dev server in the background'
    'down:stop the dev server'
    'restart:stop the dev server fully, then start it again'
    'start:start the container (does not launch the dev server)'
    'stop:stop the container (keeps DB + volumes)'
    'serve:run the dev server in the foreground'
    'logs:tail the dev server log'
    'url:print the box app URL'
    'admin:(re)create the admin user'
    'list:list boxes (with URLs) + worktrees'
    'ls:list boxes (with URLs) + worktrees'
    'rm:tear down a box'
    'help:show help'
  )

  # subcommand
  if (( CURRENT == 2 )); then
    _describe -t commands 'd-box command' cmds
    return 0
  fi

  local cmd=${words[2]}
  case $cmd in
    claude|codex|shell|rails|console|up|down|restart|start|stop|serve|logs|url|admin|rm|use|select|snapshot|snap)
      if (( CURRENT == 3 )); then
        local -a boxes
        boxes=(${(f)"$(docker ps -a --filter label=d-box --format '{{.Names}}' 2>/dev/null)"})
        if (( ${#boxes} )); then
          _describe -t boxes 'box' boxes
        else
          _message 'no boxes yet — create one with: d-box new <branch>'
        fi
        return 0   # never fall back to filename completion
      fi
      [[ $cmd == rm ]] && _values 'flag' '--delete-branch'
      return 0
      ;;
    base|rmsnap)
      if (( CURRENT == 3 )); then
        local -a snaps
        snaps=(${(f)"$(docker images "${DBOX_IMAGE%%:*}" --format '{{.Tag}}' 2>/dev/null | sed -n 's/^snap-//p')"})
        [[ $cmd == base ]] && snaps+=(default)
        _describe -t snapshots 'snapshot' snaps
      fi
      return 0
      ;;
    new)
      if (( CURRENT == 3 )); then
        local repo=${DBOX_REPO:-$HOME/work/discourse/discourse}
        local -a branches
        branches=(${(f)"$(git -C "$repo" branch --format='%(refname:short)' 2>/dev/null)"})
        (( ${#branches} )) && _describe -t branches 'branch' branches || _message 'new branch name'
      else
        _values 'flag' '--no-serve'
      fi
      return 0
      ;;
    *)
      return 0   # unknown subcommand: no filename completion
      ;;
  esac
}

# register for the script name AND a `db` alias (covers both complete_aliases settings)
compdef _d-box d-box db
