#!/bin/bash

set -euo pipefail

##############################

PARAM_CONFIG_PATH=${1:?"Missing CONFIG_PATH"}
PARAM_GIT_USER_EMAIL=${2:?"Missing GIT_USER_EMAIL"}
PARAM_GIT_USER_NAME=${3:?"Missing GIT_USER_NAME"}
PARAM_GIT_DEFAULT_BRANCH=${4:?"Missing GIT_DEFAULT_BRANCH"}
PARAM_DRY_RUN=${5:?"Missing DRY_RUN"}

##############################

# param #1: <string>
# param #2: <string>
function get_config {
  local CONFIG_PATH=$1
  local JQ_PATH=$2

  echo $(yq -o=json '.' "${CONFIG_PATH}" | jq -r "${JQ_PATH}")
}

# param #1: <string>
function get_latest_artifacthub {
  # owner/repository
  local HELM_NAME=$1

  # fetches latest version from rss feed (xml format)
  curl -sSL "https://artifacthub.io/api/v1/packages/helm/$HELM_NAME/summary"
}

# global param: <PARAM_GIT_USER_EMAIL>
# global param: <PARAM_GIT_USER_NAME>
function init_git {
  # fixes: unsafe repository ('/github/workspace' is owned by someone else)
  git config --global --add safe.directory /github/workspace

  # mandatory configs
  git config user.email $PARAM_GIT_USER_EMAIL
  git config user.name $PARAM_GIT_USER_NAME

  # fetch existing remote branches
  git fetch --all
}

# global param: <PARAM_GIT_DEFAULT_BRANCH>
function reset_git {
  # stash any changes from previous pr
  git stash save -u

  # reset to default branch
  git checkout $PARAM_GIT_DEFAULT_BRANCH
}

# param #1: <string>
# param #2: <string>
# param #3: <string>
# global param: <PARAM_GIT_DEFAULT_BRANCH>
# action param: <GITHUB_REPOSITORY>
# action param: <GITHUB_RUN_ID>
# action param: <GITHUB_TOKEN>
# see https://github.com/my-awesome/actions/blob/main/gh-update-action/update.sh
function create_pr {
  local GIT_BRANCH=$1
  local PR_TITLE=$2
  local PR_MESSAGE=$3
  local SOURCE_FILE=$4

  echo "[*] GIT_BRANCH=${GIT_BRANCH}"
  echo "[*] PR_TITLE=${PR_TITLE}"
  # echo -e "[*] PR_MESSAGE=${PR_MESSAGE}"

  # must be on a different branch
  git checkout -b $GIT_BRANCH
  git add $SOURCE_FILE
  git status

  # fails without quotes: "quote all values that have spaces"
  git commit -m "$PR_TITLE"
  git push origin $GIT_BRANCH

  # uses GITHUB_TOKEN
  gh pr create --head $GIT_BRANCH --base ${PARAM_GIT_DEFAULT_BRANCH} --title "$PR_TITLE" --body "$PR_MESSAGE"

  # retrieves latest sha of the current branch
  # global GITHUB_SHA is the commit sha that triggered the workflow, before the update
  GIT_BRANCH_SHA=$(git rev-parse $GIT_BRANCH)

  echo "[*] GIT_BRANCH_SHA=${GIT_BRANCH_SHA}"

  # uses GITHUB_TOKEN
  # https://docs.github.com/en/rest/commits/statuses#about-the-commit-statuses-api
  # push status to allow branch protection
  gh api \
    --method POST \
    -H "Accept: application/vnd.github+json" \
    "/repos/${GITHUB_REPOSITORY}/statuses/${GIT_BRANCH_SHA}" \
    -f state="success" \
    -f target_url="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" \
    -f description="Helm dependencies up to date" \
    -f context="action/helm-dependencies"

  # TODO labels https://github.com/cli/cli/issues/1503
  # TODO automerge
}

# param #1: <string>
# global param: <PARAM_DRY_RUN>
function update_dependency {
  local DEPENDENCY_JSON=$1

  local PACKAGE_NAME=$(echo ${DEPENDENCY_JSON} | jq -r '.sources[] | select(.name == "artifacthub") | .package')
  local TARGET_FILE=$(echo ${DEPENDENCY_JSON} | jq -r '.target.file')
  local TARGET_PATH=$(echo ${DEPENDENCY_JSON} | jq -r '.target.path')
  local CURRENT_VERSION=$(get_config ${TARGET_FILE} ${TARGET_PATH})
  local PACKAGE_SUMMARY=$(get_latest_artifacthub "$PACKAGE_NAME")
  local LATEST_CHART_VERSION=$(echo ${PACKAGE_SUMMARY} | yq -r '.version')
  local LATEST_APP_VERSION=$(echo ${PACKAGE_SUMMARY} | yq -r '.app_version')
  local GITHUB_SOURCE=$(echo ${DEPENDENCY_JSON} | jq -r '.sources[] | select(.name == "github")')
  local GITHUB_SOURCE_REPOSITORY=$(echo $GITHUB_SOURCE | jq -r '.repository')
  local REPOSITORY_TYPE=$(echo $GITHUB_SOURCE | jq -r '.type')

  echo "[Chart ${PACKAGE_NAME}] CURRENT=[${CURRENT_VERSION}] LATEST=[${LATEST_CHART_VERSION}]"

  if [[ ${CURRENT_VERSION} == ${LATEST_CHART_VERSION} ]]; then
    echo "[-] Dependency is already up to date"

  elif [[ "${PARAM_DRY_RUN}" == "true" ]]; then
    echo "[-] Skip pull request"

  else
    echo "Fetching changelog"
    curl -sSL "https://artifacthub.io/api/v1/packages/helm/$PACKAGE_NAME/changelog.md" -o changelog

    if jq -e . >/dev/null 2>&1 < changelog; then
      echo "[-] Changelog not found in artifacthub"

      if [ -n "$GITHUB_SOURCE" ] && [[ "${REPOSITORY_TYPE}" == "chart" ]]; then
        echo "[-] Github source with chart repository found"

        curl -L -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$GITHUB_SOURCE_REPOSITORY/releases/tags/v$LATEST_CHART_VERSION" -o release

        PR_MESSAGE="Updates [${PACKAGE_NAME}](https://artifacthub.io/packages/helm/${PACKAGE_NAME}) Helm dependency from ${CURRENT_VERSION} to ${LATEST_CHART_VERSION}\n\n"

        PR_MESSAGE="${PR_MESSAGE}\n\n# CHART CHANGELOG"
        PR_MESSAGE="${PR_MESSAGE}\n\n$(jq -r '.body' release)"
      fi
    else
      echo "[-] Changelog found"
      FIRST_HEADING=$(grep -n "^## $LATEST_CHART_VERSION" changelog | cut -d':' -f1)
      SECOND_HEADING=$(grep -n "^## $CURRENT_VERSION" changelog | cut -d':' -f1)

      sed -n "${FIRST_HEADING},${SECOND_HEADING}p" changelog | sed "$ d" > latest_changelog

      PR_MESSAGE="Updates [${PACKAGE_NAME}](https://artifacthub.io/packages/helm/${PACKAGE_NAME}) Helm dependency from ${CURRENT_VERSION} to ${LATEST_CHART_VERSION}\n\n"

      PR_MESSAGE="${PR_MESSAGE}\n\n# CHART CHANGELOG"
      PR_MESSAGE="${PR_MESSAGE}\n\n$(cat latest_changelog)"
    fi

    if [ -n "$GITHUB_SOURCE" ] && [[ "${REPOSITORY_TYPE}" == "app" ]]; then
      echo "[-] Github source with app repository found"

      curl -L -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/$GITHUB_SOURCE_REPOSITORY/releases/tags/v$LATEST_APP_VERSION" -o release

      PR_MESSAGE="${PR_MESSAGE}\n\n# APP CHANGELOG"
      PR_MESSAGE="${PR_MESSAGE}\n\n$(jq -r '.body' release)"
    else
      echo "[-] Github source with app repository not found"
    fi

    PR_MESSAGE=$(echo -e "${PR_MESSAGE}")

    # update version: see formatting issue https://github.com/mikefarah/yq/issues/515
    yq -i  "${TARGET_PATH} = \"${LATEST_CHART_VERSION}\"" ${TARGET_FILE}

    local GIT_BRANCH=$(echo "helm-${PACKAGE_NAME}-${LATEST_CHART_VERSION}" | sed -r 's|[/.]|-|g')
    local DEPENDENCY_NAME=$(basename ${PACKAGE_NAME})
    local PR_TITLE="Update ${DEPENDENCY_NAME} to ${LATEST_CHART_VERSION}"
    

    # returns the hash of the branch if exists or nothing
    # IMPORTANT branches are fetched once during setup
    local GIT_BRANCH_EXISTS=$(git show-ref ${GIT_BRANCH})

    # returns true if the string is not empty
    if [[ -n ${GIT_BRANCH_EXISTS} ]]; then
      echo "[-] Pull request already exists"
    else
      create_pr "${GIT_BRANCH}" "${PR_TITLE}" "${PR_MESSAGE}" "${TARGET_FILE}"
    fi
  fi
}

##############################

function main {
  local DEPENDENCIES=$(get_config ${PARAM_CONFIG_PATH} '.dependencies[]')

  if [[ "${PARAM_DRY_RUN}" == "true" ]]; then
    echo "[-] Skip git setup"
  else
    # setup git repository
    init_git
  fi

  # use the compact output option (-c) so each result is put on a single line and is treated as one item in the loop
  echo ${DEPENDENCIES} | jq -c '.' | while read ITEM; do
    update_dependency "${ITEM}"
    
    if [[ "${PARAM_DRY_RUN}" == "true" ]]; then
      echo "[-] Skip git reset"
    else
      # prepare git repository for next pr
      reset_git
    fi
  done
}

echo "[+] helm-dependencies"
# global
echo "[*] GITHUB_TOKEN=${GITHUB_TOKEN}"
echo "[*] GITHUB_REPOSITORY=${GITHUB_REPOSITORY}"
echo "[*] GITHUB_SHA=${GITHUB_SHA}"
# params
echo "[*] CONFIG_PATH=${PARAM_CONFIG_PATH}"
echo "[*] GIT_USER_EMAIL=${PARAM_GIT_USER_EMAIL}"
echo "[*] GIT_USER_NAME=${PARAM_GIT_USER_NAME}"
echo "[*] GIT_DEFAULT_BRANCH=${PARAM_GIT_DEFAULT_BRANCH}"
echo "[*] DRY_RUN=${PARAM_DRY_RUN}"

gh --version
gh auth status

main

echo "[-] helm-dependencies"
