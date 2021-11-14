export EDITOR="vim"

# Config terminal
export PS1='[\t \u@\h:\w]\n$ '

# Personal aliases
alias att="tmux attach -t"
alias c=clear
alias ll="ls -alF"
alias pull="git pull && git submodule sync && git submodule update --init --recursive"
alias with-proxy >/dev/null 2>&1 || alias with-proxy=""

# PyTorch environment variables.
export CFLAGS="-fomit-frame-pointer"
export REL_WITH_DEB_INFO=1
export TORCH_CUDA_ARCH_LIST=8.0

# Define: make_clean_env, config_env, build_develop, build_install
source "$(dirname ${BASH_SOURCE[0]})/.build_helpers.sh"
_helper_init
