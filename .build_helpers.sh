# Helper functions for building PyTorch (On both Devserver/DevGPU and AWS cluster.)
#   make_clean_env
#       Fixing (or even diagnosing) a sick environment is very time consuming.
#       When in doubt, just nuke it and go back to a good starting point.
#
#   config_env
#       Conda can associate an environment variable with a conda env. Tired of
#       remembering where CUDA_HOME should be, or having to rebuild because you ran
#           `USE_CUDA=0 USE_FBGEMM=0 BUILD_TEST=0 USE_NNPACK=0 USE_QNNPACK=0 USE_DISTRIBUTED=0 USE_TENSORPIPE=0 USE_GLOO=0 USE_MPI=0 BUILD_CAFFE2_OPS=0 BUILD_CAFFE2=0 REL_WITH_DEB_INFO=ON MAX_JOBS=32 python setup.py develop`
#       but you meant to run
#           `USE_CUDA=1 USE_FBGEMM=0 BUILD_TEST=0 USE_NNPACK=0 USE_QNNPACK=0 USE_DISTRIBUTED=0 USE_TENSORPIPE=0 USE_GLOO=0 USE_MPI=0 BUILD_CAFFE2_OPS=0 BUILD_CAFFE2=0 REL_WITH_DEB_INFO=ON MAX_JOBS=32 python setup.py develop`
#       (This is WIP. Feel free to suggest your own favorite config options.)
#
#   build_develop
#   build_install
#       Abstracts away the `srun` command, so the same build command works
#       everywhere. Plus it checks that you are actually in a conda env.
#       The number of times I've contaminated my base env and not noticed...
#
#   ammend_to
#       Helper to add to a prior commit. (e.g. `ammend_to HEAD` or `ammend_to HEAD~3`)
#       Very helpful with ghstack, where rebasing can otherwise get very dicy. Plus
#       there are lots of checks so you don't accidentally bork your repo or lose
#       your changes.
#


function _helper_conda_available() {
    $(command -v conda &> /dev/null) && \
    $(command -v activate &> /dev/null)
}

function _helper_fail {
    printf '%s\n' "FAIL: $1" >&2
    : "${__fail_fast:?$1}";
}

function _helper_init() {
    # This config is quite cheap, so we rerun it frequently to make sure we pick
    # up any changes since the shell started.

    # On the AWS cluster we have to run with srun, while on devserver we run locally.
    export _HELPER_USE_SRUN="$(if [ $(command -v srun) ]; then echo true; fi)"

    # By default aliases are not used in non-interactive contexts.
    # TODO: reuse aliases.
    export _HELPER_CPURUN=$(if [ ${_HELPER_USE_SRUN} ]; then echo "srun -t 5:00:00 --cpus-per-task=24"; fi)
    export _HELPER_GPURUN=$(if [ ${_HELPER_USE_SRUN} ]; then echo "srun -p dev --cpus-per-task=16 -t 5:00:00 --gpus-per-node=2"; fi)

    # Sometimes conda needs a bit of help to get going.
    if ! _helper_conda_available; then
        if [ ! -z "${CONDA_EXE}" ]; then
            CONDA_BIN=$(dirname ${CONDA_EXE})
            if [[ ! $PATH == *"$CONDA_BIN"* && -f ${CONDA_BIN}/activate ]]; then
                export PATH="${PATH}:${CONDA_BIN}"
            fi
        fi
    fi
}

function _helper_assert_in_env() {
    _helper_conda_available || _helper_fail "Conda is not available."
    if [ ! "${CONDA_PREFIX}" ]; then _helper_fail "Not in a conda env."; fi
    if [[ "${CONDA_DEFAULT_ENV}" == "base" ]]; then _helper_fail "Do not mess with the base env."; fi
}

function _helper_test_https() {
    curl https://github.com 2>1 > /dev/null || \
    _helper_fail "Unable to verify https connectivity. Do you need to use a proxy? (e.g. `with-proxy`)"
}

function _helper_build() {
    _helper_init || _helper_fail "init"
    _helper_assert_in_env
    if [ -z "${USE_CUDA}" ]; then
        echo "Warning: USE_CUDA is not set."
        echo "If build fails, try \`config_env cuda off\` or \`config_env cuda 11.0\`"
        echo "(and \`make clean\` before you retry)"
    fi

    if [ "${USE_CUDA}" == "1" ] && [ ! -z ${CUDA_HOME} ]; then
        PATH="${CUDA_HOME}/bin:$PATH"
    fi
    ${_HELPER_CPURUN} python setup.py $1
}

function make_clean_env() {
    _helper_init || _helper_fail "init"

    ENV_NAME="$1"
    if [ ! "${ENV_NAME}" ]; then
        echo "Usage: make_clean_env ENV_NAME [PY_VERSION]"
        echo "Create a new conda environment and configure for PyTorch."
        echo "Example: make_clean_env my_env 3.8"
    fi

    # Make sure we are in a clean state. (10 deep should be plenty...)
    _helper_conda_available || _helper_fail "Conda is not available"
    for i in {1..10}; do
        if [ ! -z $CONDA_PREFIX ]; then
            conda deactivate || true
        fi
    done

    GENERIC_INSTALLS="numpy ninja pyyaml mkl mkl-include setuptools cmake cffi hypothesis"

    CONDA_FORGE_INSTALLS="expecttest valgrind"
    if ! $(git lfs 2>1 > /dev/null); then
        CONDA_FORGE_INSTALLS="${CONDA_FORGE_INSTALLS} git-lfs"
    fi

    PY_VERSION="${2:-3.7}"
    if [[ "${PY_VERSION}" == "3.7" ]]; then
        GENERIC_INSTALLS="${GENERIC_INSTALLS} typing_extensions dataclasses"
    elif [[ "${PY_VERSION}" == "3.8" ]]; then
        true
    elif [[ "${PY_VERSION}" == "3.9" ]]; then
        true
    else
        _helper_fail "Unknown PY_VERSION=${PY_VERSION}"
    fi

    conda env remove --name "${ENV_NAME}" 2> /dev/null || _helper_fail "Cleanup old env: ${ENV_NAME}"
    conda create --no-default-packages -y -n "${ENV_NAME}" python="${PY_VERSION}" || _helper_fail "Make env: ${ENV_NAME}"
    
    {
        # Install packages.
        conda activate &&
        . activate "${ENV_NAME}" &&
        conda install -y $GENERIC_INSTALLS &&
        conda install -y -c conda-forge $CONDA_FORGE_INSTALLS
    } || {
        # Cleanup if install fails.
        echo "Cleaning up failed env"
        conda env remove --name "${ENV_NAME}" 2> /dev/null
        return 1
    }

    if [ ! $(command -v ghstack) ]; then
        _helper_test_https
        pip install ghstack || _helper_fail "Install ghstack"
    fi

    # Drop back to base env.
    conda deactivate && conda activate
    printf "\nENV:    ${ENV_NAME}\nPython: ${PY_VERSION}\n\n"
}

function config_env() {
    _helper_init || _helper_fail "init"
    _helper_assert_in_env

    function _choices() {
        echo "Choices:"
        echo "  clean"
        echo "  cuda 11.0"
        echo "  cuda 10.2"
        echo "  cuda off"
        echo "  fast_build"
    }

    if [[ ! "${1}" ]]; then
        _choices
        return 0

    elif [[ "${1}" == "clean" ]]; then
        unset USE_CUDA 
        unset CUDA_HOME
        unset BUILD_TEST
        unset BUILD_CAFFE2_OPS
        unset BUILD_CAFFE2
        conda env config vars unset USE_CUDA CUDA_HOME BUILD_TEST BUILD_CAFFE2_OPS BUILD_CAFFE2 > /dev/null

    elif [[ "${1}" == "cuda" && "${2}" == "11.0" ]]; then

        # The AWS cluster has system cuda installs. On DevGPU we have to use conda.
        if [ -d "/usr/local/cuda-11.0/" ]; then
            export CUDA_HOME="/usr/local/cuda-11.0/"
        else
            conda install -y -c conda-forge cudatoolkit-dev=11.0 cudnn || _helper_fail "Install CUDA 11.0"
            export CUDA_HOME="${CONDA_PREFIX}/pkgs/cuda-toolkit/"
        fi

        export USE_CUDA=1
        conda env config vars set USE_CUDA=1 CUDA_HOME="${CUDA_HOME}" > /dev/null

    elif [[ "${1}" == "cuda" && "${2}" == "10.2" ]]; then

        # The AWS cluster has system cuda installs. On DevGPU we have to use conda.
        if [ -d "/usr/local/cuda-10.2/" ]; then
            export CUDA_HOME="/usr/local/cuda-10.2/"
        else
            _helper_fail "CUDA 10.2 is only on the AWS cluster. (Because I'm too lazy to set it up for DevGPU.)"
        fi

        export USE_CUDA=1
        conda env config vars set USE_CUDA=1 CUDA_HOME="${CUDA_HOME}" > /dev/null

    elif [[ "${1}" == "cuda" && "${2}" == "off" ]]; then
        export USE_CUDA=0
        conda env config vars set USE_CUDA=0 > /dev/null

    elif [[ "${1}" == "fast_build" ]]; then
        export BUILD_TEST=0
        export BUILD_CAFFE2_OPS=0
        export BUILD_CAFFE2=0
        conda env config vars set BUILD_TEST=0 BUILD_CAFFE2_OPS=0 BUILD_CAFFE2=0 > /dev/null

    else
        _choices
        echo
        _helper_fail "Unknown choice: ${1} ${2}"

    fi
}

function build_develop() {
    _helper_build develop
}

function build_install() {
    _helper_build install
}

ammend_to() {
    # Based on: https://stackoverflow.com/questions/1186535/how-to-modify-a-specified-commit
    SHA=$(git rev-parse ${1} 2> /dev/null)
    if [ $? -ne 0 ]; then
        echo "Cannot resolve ${1}"
        return 1
    fi

    git log -1 $SHA
    read -r -p "Continue? [y/N] " response
    response=${response,,}    # tolower
    if [[ "$response" =~ ^(yes|y)$ ]]; then
        CHECKPOINT=$(git rev-parse HEAD)
        git stash -k || _helper_fail "stash"

        function cleanup_failure() {
            # Everything (including the staged changes) was stored when we stash.
            git reset --hard "${CHECKPOINT}"
            git stash pop
            _helper_fail "${1}"
        }

        git commit --fixup "${SHA}" || cleanup_failure "Commit failed."

        {
            GIT_SEQUENCE_EDITOR=true git rebase --interactive --autosquash "$SHA^"
        } || {
            git rebase --abort
            cleanup_failure "Rebase failed."
        }

        git stash pop
    fi
}


