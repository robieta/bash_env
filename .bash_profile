export EDITOR="vim"

# Config terminal
export PS1='[\t \u@\h:\w]\n$ '

alias att="tmux attach -t"
alias c=clear
alias ll="ls -alF"
alias pull="git pull && git submodule sync && git submodule update --init --recursive"

alias generic_build_flags="USE_FBGEMM=0 BUILD_TEST=0 USE_NNPACK=0 USE_QNNPACK=0 USE_DISTRIBUTED=0 USE_TENSORPIPE=0 USE_GLOO=0 USE_MPI=0 BUILD_CAFFE2_OPS=0 BUILD_CAFFE2=0 REL_WITH_DEB_INFO=1"
alias simple_build="USE_CUDA=0 generic_build_flags"
alias cuda_build="USE_CUDA=1 TORCH_CUDA_ARCH_LIST=7.0 generic_build_flags"

if [ $(which srun &> /dev/null) ]; then
    alias maybe_run_remote="srun --cpus-per-task=24 -t 5:00:00"
else 
    alias maybe_run_remote=""
fi

alias build_develop_remote="simple_build maybe_run_remote python setup.py develop"
alias build_install_remote="simple_build maybe_run_remote python setup.py install"

alias cuda_build_develop_remote="cuda_build maybe_run_remote python setup.py develop"
alias cuda_build_install_remote="cuda_build maybe_run_remote python setup.py install"

# CUDA_HOME="/usr/local/cuda-11.0/" CMAKE_PREFIX_PATH=${CONDA_PREFIX:-"$(dirname $(which conda))/../"} PATH="/usr/local/cuda-11.0/bin:$PATH" cuda_build_install_remote


CONDA_PATH=$(which conda)
if [ -z $CONDA_PATH ]; then
    echo "Could not find conda"
else
    conda deactivate || true
    CONDA_BIN=$(dirname ${CONDA_PATH})
    if [[ ! $PATH == *"$CONDA_BIN"* && -f ${CONDA_BIN}/activate ]]; then
      export PATH="${PATH}:${CONDA_BIN}"
    fi
    conda activate || true
fi


function make_clean_env() {
    ENV_NAME="$1"
    if [ -z $ENV_NAME ]; then
        echo "ENV_NAME cannot be empty"
        exit 1
    fi

    PY_VERSION="${2:-3.7}"
    function cleanup_env() {
        conda env remove --name "${ENV_NAME}" 2> /dev/null || true
    }

    function fail {
        cleanup_env
        printf '%s\n' "FAIL: $1" >&2
        : "${__fail_fast:?$1}";
    }

    function make_env() {
        conda deactivate || true
        conda create --no-default-packages -yn "${ENV_NAME}" python="${PY_VERSION}"
        source activate "${ENV_NAME}"
        conda install -y numpy ninja pyyaml mkl mkl-include setuptools cmake cffi hypothesis typing_extensions dataclasses
        conda install -y valgrind -c conda-forge
        conda deactivate || true
        conda activate || true
    }

    cleanup_env
    make_env || fail "make_env"
    printf "\nENV:    ${ENV_NAME}\nPython: ${PY_VERSION}\n\n"
}

function build_cuda() {
    if [ "$(realpath "${CONDA_PREFIX}")" != "$(realpath "${CONDA_DIR}/envs/master")" ]; then
        echo "Wrong env, expected 'master'"
        return 1
    fi
    INITIAL_CWD="$(pwd)"
    echo $INITIAL_CWD
    function fail {
        cd $INITIAL_CWD
        printf '%s\n' "FAIL: $1" >&2
        : "${__fail_fast:?$1}";
    }

    cd ~/cluster/repos/pytorch_01
    git checkout master || fail "checkout master"
    pull || fail "pull"
    conda install -y cudatoolkit=11.0 -c nvidia || fail "install cuda 11.0"
    CUDA_HOME="/usr/local/cuda-11.0/"
    CMAKE_PREFIX_PATH=${CONDA_PREFIX:-"$(dirname $(which conda))/../"}
    PATH="/usr/local/cuda-11.0/bin:$PATH"
    cuda_build_install_remote || fail "build PyTorch"

    cd ~/cluster/repos/vision
    git checkout main || fail "checkout main"
    pull || fail "pull"
    srun --cpus-per-task=24 -t 5:00:00 python setup.py install || fail "install vision"

    cd ~/cluster/repos/text
    git checkout main || fail "checkout main"
    pull || fail "pull"
    srun --cpus-per-task=24 -t 5:00:00 python setup.py install || fail "install text"

    cd $INITIAL_CWD
}


