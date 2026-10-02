# Sourced by run scripts. Loads repo-root .env into the environment without
# printing values. Existing env vars win over .env (so CI/tests can override).
# Safe for KEY=VALUE lines; ignores blanks and # comments.
if [[ -z "${_FILO_ENV_LOADED:-}" ]]; then
  _FILO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  _FILO_ENV="${FILO_ENV_FILE:-$_FILO_ROOT/.env}"
  if [[ -f "$_FILO_ENV" ]]; then
    if [[ "$(uname -s)" == "Darwin" || "$(uname -s)" == "Linux" ]]; then
      _mode="$(stat -f '%Lp' "$_FILO_ENV" 2>/dev/null || stat -c '%a' "$_FILO_ENV" 2>/dev/null || echo "")"
      if [[ -n "$_mode" && "$_mode" != "600" && "$_mode" != "400" ]]; then
        echo "warning: $_FILO_ENV mode is $_mode (recommend chmod 600)" >&2
      fi
    fi
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      _line="${_line%$'\r'}"
      [[ -z "$_line" || "$_line" == \#* ]] && continue
      if [[ "$_line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        _k="${match[1]}"
        _v="${match[2]}"
        # Strip optional surrounding quotes
        if [[ "$_v" == \"*\" && "$_v" == *\" ]]; then
          _v="${_v:1:${#_v}-2}"
        elif [[ "$_v" == \'*\' && "$_v" == *\' ]]; then
          _v="${_v:1:${#_v}-2}"
        fi
        # Do not overwrite vars already set in the shell / CI
        if [[ -z "${(P)_k:-}" ]]; then
          export "$_k=$_v"
        fi
      fi
    done < "$_FILO_ENV"
  fi
  unset _FILO_ROOT _FILO_ENV _mode _line _k _v
  _FILO_ENV_LOADED=1
fi
