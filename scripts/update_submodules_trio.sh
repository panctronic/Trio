#!/bin/zsh
#
# Checks out and pulls the tracked branch of every submodule listed in
# scripts/define_common_trio.sh. Run from anywhere inside the Trio checkout.
#
# Stops at the first failure. Each submodule is updated in a subshell, so a
# failed `cd` can never make the git commands run in the parent repository.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

source scripts/define_common_trio.sh

for project in ${TRIO_PROJECTS}; do
  IFS=":" read -r user dir branch <<< "$project"
  echo "Updating $dir to $branch on $user/$dir"
  if [[ -z "$dir" || -z "$branch" || ! -e "$dir/.git" ]]; then
    echo "error: '$dir' is not an initialised submodule (run: git submodule update --init --recursive)" >&2
    exit 1
  fi
  (
    cd "$dir" || exit 1
    git checkout "$branch"
    git pull
  )
done
