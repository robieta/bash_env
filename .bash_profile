export EDITOR="vim"

# Config terminal
export PS1='[\t \u@\h:\w]\n$ '

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# Personal aliases
alias att="tmux attach -t"
alias c=clear
alias ll="ls -alF"
alias pull="git pull && git submodule sync && git submodule update --init --recursive"
alias with-proxy >/dev/null 2>&1 || alias with-proxy=""

# Automatically (re)attach to tmux session upon ssh.
if [[ -z "$TMUX" ]] && [[ -n "$SSH_CONNECTION" ]]; then
  tmux attach-session -t ssh_tmux || tmux new-session -s ssh_tmux
fi

# PyTorch environment variables.
export CFLAGS="-fomit-frame-pointer"
export REL_WITH_DEB_INFO=1
export TORCH_CUDA_ARCH_LIST=8.0  # A100

# Define: make_clean_env, config_env, build_develop, build_install
source "$(dirname ${BASH_SOURCE[0]})/.build_helpers.sh"
_helper_init
