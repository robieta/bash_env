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
#       everywhere. Plus it checks that you are actually in a conda env (the
#       number of times I've contaminated my base env and not noticed...) and
#       some other common missteps.
#
#   ammend_to
#       Helper to add to a prior commit. (e.g. `ammend_to HEAD` or `ammend_to HEAD~3`)
#       Very helpful with ghstack, where rebasing can otherwise get very dicy. Plus
#       there are lots of checks so you don't accidentally bork your repo or lose
#       your changes.
#

function pip(){
  if [ "${CONDA_PROMPT_MODIFIER-}" = "(base) " ] && [ "$1" = "install" ]; then
    echo "Not allowed in base"
  else
    command pip "$@"
  fi
}

function _extended_conda(){
  if [ "${CONDA_PROMPT_MODIFIER-}" = "(base) " ] && [ "$1" = "install" ]; then
    echo "Not allowed in base"
  else
    conda "$@"
  fi
}
alias conda=_extended_conda


function _helper_conda_available() {
    $(command -v conda &> /dev/null) && \
    $(command -v activate &> /dev/null)
}

function _helper_fail {
    printf '%s\n' "FAIL: $1" >&2
    : "${__fail_fast:?$1}";
}

function _helper_init() {
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
    PY_VERSION="${2:-3.11}"
    if [ ! "${ENV_NAME}" ]; then
        echo "Usage: make_clean_env ENV_NAME [PY_VERSION]"
        echo "Create a new conda environment and configure for PyTorch."
        echo "Example: make_clean_env my_env 3.11"
    fi

    # Make sure we are in a clean state. (10 deep should be plenty...)
    _helper_conda_available || _helper_fail "Conda is not available"
    for i in {1..10}; do
        if [ ! -z $CONDA_PREFIX ]; then
            conda deactivate || true
        fi
    done

    conda env remove --name "${ENV_NAME}" 2> /dev/null || _helper_fail "Cleanup old env: ${ENV_NAME}"
    conda create --no-default-packages -y -n "${ENV_NAME}" python="${PY_VERSION}" || _helper_fail "Make env: ${ENV_NAME}"

    # Drop back to base env.
    conda deactivate && conda activate
    printf "\nENV:    ${ENV_NAME}\nPython: ${PY_VERSION}\n\n"
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
