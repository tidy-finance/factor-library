#!/usr/bin/env bash
# Sets up a UCloud Terminal job for the build of the factor library: the code,
# uvr, R, the packages, the Hugging Face CLI, the credentials, and the memory
# settings. Select this file as the Initialization parameter of the job, with
# the drive folder factor-library mounted. Only /work survives a job, so
# everything that should last lives there.
#
# With a script number in Extra options, for example 1, the script also runs
# the scripts from that number to 06 in the tmux session "build"; attach to it
# with `tmux attach -t build`. 07 uploads to Hugging Face, so it runs by hand
# once 06 has passed.

work=/work/factor-library
repo=$work/repo
start_from=${1:-}

if [ ! -d "$repo/.git" ]; then
  git clone https://github.com/tidy-finance/factor-library.git "$repo"
fi
cd "$repo"
# A run with old code wastes the job, so a failed pull starts no run.
if ! git checkout main || ! git pull --ff-only; then
  echo "git pull failed: set up the job, but start no run" >&2
  start_from=""
fi

# uvr, the Hugging Face CLI, and its login live in /work and survive the job;
# R and the system libraries do not.
export PATH="$work/bin:$PATH" HF_HOME="$work/huggingface"
if [ ! -x "$work/bin/uvr" ]; then
  curl -fsSL https://raw.githubusercontent.com/nbafrank/uvr/main/install.sh |
    UVR_INSTALL_DIR="$work/bin" sh
fi
uvr r install 4.6.1
uvr sync --frozen --install-system-deps
# The R library in the repository survives the job, so uvr sync finds every
# package installed and installs no system libraries. tidyfinance loads
# RPostgres for WRDS, which needs libpq; the Hugging Face CLI needs Python.
sudo apt-get update -qq
sudo apt-get install -y libpq5 python3-venv
if [ ! -x "$work/bin/hf" ]; then
  curl -LsSf https://hf.co/cli/install.sh |
    HF_CLI_BIN_DIR="$work/bin" bash -s -- --no-modify-path
fi

# R under uvr run does not read .Renviron, so the shell exports the WRDS
# credentials. The OSAP file unzips to more than 6 GB, so the temporary folder
# is on /work. glibc keeps memory that R frees; fixed thresholds return large
# vectors to the system. One linear-algebra thread per worker keeps the 40
# workers from starting a thread with its own buffer for every core. These
# settings must exist before R starts.
mkdir -p "$work/tmp"
cat >> "$HOME/.bashrc" <<SETTINGS
export PATH="$work/bin:\$PATH" HF_HOME="$work/huggingface" TMPDIR="$work/tmp"
export R_CONFIG_ACTIVE=cloud OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1
export MALLOC_ARENA_MAX=2 MALLOC_MMAP_THRESHOLD_=131072 MALLOC_TRIM_THRESHOLD_=131072
cd "$repo"
set -a; [ -f .Renviron ] && source .Renviron; set +a
# Runs the scripts from the given number to 06 and stops at the first that
# fails; build.log records when each started.
build() {
  for script in 0[1-6]_*.R; do
    [ "\${script:0:2}" -ge "\$1" ] || continue
    echo "\$(date '+%F %T') \$script" >> "$work/build.log"
    if ! uvr run "\$script"; then
      echo "\$(date '+%F %T') \$script failed" >> "$work/build.log"
      return 1
    fi
  done
  echo "\$(date '+%F %T') done" >> "$work/build.log"
}
SETTINGS

if [ -n "$start_from" ]; then
  tmux new-session -d -s build "bash -ic 'build $start_from; exec bash'"
fi
