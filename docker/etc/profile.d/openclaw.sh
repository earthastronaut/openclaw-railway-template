# /app/bin and Homebrew on PATH, plus the `cdw` alias, for login shells.
# /etc/profile rebuilds PATH, so these directories are prepended again here.
# Interactive non-login bash sources this file from /etc/bash.bashrc.
for d in /home/linuxbrew/.linuxbrew/sbin /home/linuxbrew/.linuxbrew/bin /app/bin; do
  case ":$PATH:" in
    *":$d:"*) ;;
    *) PATH="$d:$PATH" ;;
  esac
done
export PATH
alias cdw='cd "${OPENCLAW_WORKSPACE_DIR:-${OPENCLAW_STATE_DIR:-/data/.openclaw}/workspace}"'
