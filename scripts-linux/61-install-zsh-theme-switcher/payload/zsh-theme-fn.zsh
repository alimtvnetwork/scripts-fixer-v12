# Provides the 'zsh-theme' command. Usage:
#   zsh-theme               # interactive numbered menu
#   zsh-theme agnoster      # switch immediately
#   zsh-theme --list        # list themes
#   zsh-theme --current     # show current theme
#   zsh-theme --random      # pick a random theme from the configured list
zsh-theme() {
  emulate -L zsh
  local zshrc="$HOME/.zshrc"
  local omz_themes="${ZSH:-$HOME/.oh-my-zsh}/themes"
  local cfg="__LOVABLE_CFG_PATH__"
  local -a themes
  local current
  current=$(grep -E '^ZSH_THEME=' "$zshrc" 2>/dev/null | head -1 | sed -E 's/^ZSH_THEME="?([^"]*)"?.*/\1/')

  if [[ -r "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    themes=("${(@f)$(jq -r '.themes[], .custom_themes[]' "$cfg" 2>/dev/null)}")
  else
    themes=(agnoster robbyrussell af-magic avit bira candy fishy gnzh half-life)
  fi

  case "${1:-}" in
    --list|-l)
      printf '%s\n' "${themes[@]}"
      return 0
      ;;
    --current|-c)
      print -- "Current ZSH_THEME: ${current:-<unset>}"
      return 0
      ;;
    --random|-r)
      local pick=${themes[$((RANDOM % ${#themes[@]} + 1))]}
      zsh-theme "$pick"
      return $?
      ;;
    --help|-h)
      cat <<'EOF'
zsh-theme -- switch Oh-My-Zsh theme

Usage:
  zsh-theme                interactive numbered menu
  zsh-theme <name>         switch immediately to <name>
  zsh-theme --list         list configured themes
  zsh-theme --current      print current ZSH_THEME
  zsh-theme --random       pick a random theme
  zsh-theme --help         this help
EOF
      return 0
      ;;
  esac

  local target="$1"

  # Interactive numbered menu when no name provided
  if [[ -z "$target" ]]; then
    print -- ""
    print -- "ZSH theme switcher (current: ${current:-<unset>})"
    print -- "------------------------------------------------"
    local i=1
    for t in "${themes[@]}"; do
      if [[ "$t" == "$current" ]]; then
        printf '  %2d) %s  *\n' "$i" "$t"
      else
        printf '  %2d) %s\n' "$i" "$t"
      fi
      ((i++))
    done
    print -- ""
    local choice
    read "choice?Pick a number (1-${#themes[@]}), name, or blank to cancel: "
    if [[ -z "$choice" ]]; then
      print -- "Aborted."
      return 1
    fi
    if [[ "$choice" == <-> ]] && (( choice >= 1 && choice <= ${#themes[@]} )); then
      target=${themes[$choice]}
    else
      target=$choice
    fi
  fi

  # Validate theme exists on disk if OMZ themes dir is present
  if [[ -d "$omz_themes" ]]; then
    if [[ ! -f "$omz_themes/${target}.zsh-theme" ]] && [[ ! -d "$omz_themes/$(dirname $target 2>/dev/null)" ]]; then
      print -u2 -- "warn: theme file not found: $omz_themes/${target}.zsh-theme (continuing anyway)"
    fi
  fi

  # Edit ~/.zshrc
  if [[ ! -f "$zshrc" ]]; then
    print -u2 -- "error: $zshrc does not exist"
    return 2
  fi
  if grep -qE '^ZSH_THEME=' "$zshrc"; then
    sed -i.bak -E "s|^ZSH_THEME=.*|ZSH_THEME=\"${target}\"|" "$zshrc"
  else
    print -- "ZSH_THEME=\"${target}\"" >> "$zshrc"
  fi
  print -- "ZSH_THEME -> '${target}'. Reloading shell..."
  exec zsh
}
