#!/bin/bash

set -e

declare -xr EDITOR="${EDITOR:-vim}"
declare -xr DEPENDENCIES=(mkdir diff sed vault jq)
declare -xr NOT_INSTALLED=2

function show_usage() {
cat << USAGE
Options:
  -d <path> : Sets working directory on the local disk.
              Current directory is used by default

  -h        : Prints usage and exit
  -q        : Prints Vault and Error messages only
  -r        : Makes dump and import recursively
  -t        : Tests only (dry-run mode). Applicable for import command. Nothing
            : will be written to Vault
  -v        : Increases verbosity

Commands:
  dump      : Reads secrets from vault and stores their content to appropriate
              files on the local disk. Optionally specific secret or directory
              can be passed as argument. Default value is secret/
  edit      : Runs editor and opens json for specified secret. Secret path
              should be provided as argument secret/foo.
              Editor to run can be configured via EDITOR environment variable.
              Default editor is vim
  import    : Writes content from JSON files to appropriate secrets in Vault.
              Path should be provided as an argument
  sync      : Synchronizes state of secrets in Vault with the state of secrets
              in configuration repository. It means it removes all the secrets
              from Vault that are removed from configuration repository and
              updates all the secrets that are updated
USAGE
}

# Prints ERROR message to STDERR
# Globals:
#   None
# Arguments:
#   Message to print
# Returns:
#   None
function log_error() {
  echo "[ERROR] $*" >&2
}

# Prints DEBUG message to STDOUT
# Globals:
#   VERBOSE
# Arguments:
#   Message to print
# Returns:
#   None
function log_verbose() {
  if [ "${VERBOSE}" -eq 1 ]; then
    echo "[DEBUG] $*"
  fi
}

# Prints INFO message to STDOUT
# Globals:
#   QUIET
# Arguments:
#   Message to print
# Returns:
#   None
function log_info() {
  if [ "${QUIET}" -eq 0 ]; then
    echo "[INFO] $*"
  fi
}

function log_dryrun() {
  echo "[DRY-RUN] $*"
}

# Checks if the binary is exist in the system
# and exits with an error if it is not
# Globals:
#   NOT_INSTALLED - return code to exit in case of error with
# Arguments:
#   Name of the binary to check in PATH
# Returns:
#   None
function checkb() {
  local binary="${1}"

  log_verbose "Checking for ${binary}"

  if ! command -v "${binary}" &> /dev/null; then
    log_error "Please install ${binary}"
    exit "${NOT_INSTALLED}"
  fi
}

# Dumps value of the secret from the specified path in Vault
# to the specified directory as JSON files either recursively or not
# Globals:
#   RECURSIVE - dump secrets recursively
# Arguments:
#   Path to dump secrets from
#   Directory where to store JSON files with secrets
# Returns:
#   None
function vault_dump() {
  local -r path="${1}"
  local -r working_dir="${2}"
  local filesystem_path
  local new_path

  while IFS= read -r value; do
    new_path="${path}${value}"
    filesystem_path="${working_dir}/${new_path}"
    if [ "${value: -1}" == '/' ]; then
      if [ "${RECURSIVE}" -eq 1 ]; then
        log_verbose "Create directory ${filesystem_path}"
        mkdir -p "${filesystem_path}"
        vault_dump "${new_path}" "${working_dir}"
      else
        log_verbose "Non-recursive. Skip directory ${new_path}"
        continue
      fi
    else
      log_verbose "Dump ${new_path}"
      vault read --format=json "${new_path}" \
        | jq '.data' > "${filesystem_path}".json
    fi
  done < <(vault list "${path}" | grep -Ev 'Ke|----|^$')
}

# Copies secrets from one location to another
# Globals:
#   None
# Arguments:
#   Location to copy secrets from
#   Location to copy secrets to
# Returns:
#   None
function copy {
  local src="${1}"
  local dst="${2}"

  if [ "${src: -1}" == '/' ] && [ "${dst: -1}" == '/' ]; then
    mkdir -p "${dst}"
    cp -r "${src}"/* "${dst}"/
  elif [ "${src: -1}" != '/' ] && [ "${dst: -1}" != '/' ]; then
    mkdir -p "${dst%/*}"
    cp -r "${src}" "${dst}"
  else
    log_error "Please, pass valid source and destination paths:\\n\
      ${src} - ${dst}"
  fi
}

# Opens JSON file with secret's value in a favourite editor
# Globals:
#   EDITOR
# Arguments:
#   Location of the secret to edit
# Returns:
#   None
function edit {
  local path="${1}"

  checkb "${EDITOR}"

  if [ "${path: -1}" == '/' ]; then
    log_error "Please, pass valid secret path: ${path}"
  else
    ${EDITOR} "${path}"
  fi
}

# Imports secrets tree specified by path to the Vault using JSON files
# located at the provided directory. All existing values will be overwritten
# Globals:
#   RECURSIVE - imports secrets recursively
#   DRY_RUN - nothing will be written to Vault.
#             Vault write commands will be printed only
# Arguments:
#   Path to import secrets to
#   Directory where JSON files with secrets are stored
# Returns:
#   None
function vault_import {
  local -r root_path="${1}"
  local -r working_dir="${2}"
  local find_options=''
  local vault_path

  if [ "${RECURSIVE}" -eq 0 ]; then
    find_options='-maxdepth 1'
  fi

  while IFS= read -r file_path
  do
    # Get path in Vault by removing directory path and json file extension
    vault_path="${file_path#${working_dir}/}"
    vault_path="${vault_path%.json}"
    if [ "${DRY_RUN}" -eq 1 ]; then
      log_dryrun "vault write ${vault_path} @${file_path}"
    else
      log_verbose "Import ${vault_path}"
      vault write "${vault_path}" @"${file_path}"
    fi
  done < <(eval find "${working_dir}/${root_path}" \
                  "${find_options}" -type f -name '*.json')
}

# Synchronizes secrets tree specified by path to the Vault using JSON files
# located at the provided directory.
# All secrets that are not present at specified source directory will be
# removed from Vault
# The only secrets which values are different in source directory and Vault
# will be written to Vault.
# Values from configuration files have precendence over ones from Vault
# Globals:
#   RECURSIVE - imports secrets recursively
#   DRY_RUN - nothing will be written to Vault.
#             Vault write commands will be printed only
#   WORKING_DIR - directory where JSON files with secrets are stored
# Arguments:
#   Path to import secrets to
# Returns:
#   None
function vault_sync_tree {
  local -r root_path="${1}"
  local -r source_dir="${WORKING_DIR}/${root_path}"
  local dump_tmp_dir
  local relative_file_path
  local target_dir
  local vault_path

  dump_tmp_dir=$(mktemp -d --tmpdir="${WORKING_DIR}")
  target_dir="${dump_tmp_dir}/${root_path}"
  readonly dump_tmp_dir
  readonly target_dir

  vault_dump "${root_path}" "${dump_tmp_dir}"
  # Delete removed secrets
  log_verbose "Delete secrets removed from configuration repository"
  while IFS= read -r file_path 
  do
    # Get path in Vault by removing directory path and json file extension
    relative_file_path="${file_path#${dump_tmp_dir}/}"
    vault_path="${relative_file_path%.json}"
    log_verbose "Check ${vault_path}"
    if [ ! -e "${WORKING_DIR}/${relative_file_path}" ]; then
      if [ "${DRY_RUN}" -eq 1 ]; then
        log_dryrun "vault delete ${vault_path}"
        log_dryrun "rm -f ${file_path}"
      else
        log_verbose "Delete ${vault_path}"
        vault delete "${vault_path}"
        rm -f "${file_path}"
      fi
    fi
  done < <(find "${target_dir}"  -type f -name '*.json')
  # Update changed secrets only
  while IFS= read -r file_path
  do
    # Get path in Vault by removing directory path and json file extension
    vault_path="${file_path#${WORKING_DIR}/}"
    vault_path="${vault_path%.json}"
    log_verbose "Updating ${vault_path}"
    if [ "${DRY_RUN}" -eq 1 ]; then
      log_dryrun "vault write ${vault_path} @${file_path}"
    else
      log_verbose "Import ${vault_path}"
      vault write "${vault_path}" @"${file_path}"
    fi
  done < <(diff -Nqrw "${source_dir}" "${target_dir}" \
             | sed 's/Files \(.*\) and \(.*\)/\1/g')
}


WORKING_DIR=$(pwd)
RECURSIVE=0
DRY_RUN=0
VERBOSE=0
QUIET=0

while getopts ":d:hqrtv" option; do
  case $option in
    d) WORKING_DIR="${OPTARG}";;
    h) show_usage && exit 0;;
    r) RECURSIVE=1;;
    t) DRY_RUN=1;;
    v) VERBOSE=1;;
    q) QUIET=1;;
    *) show_usage && exit 1;;
  esac
done
shift $((OPTIND-1))

if [ $# -lt 1 ]; then
  show_usage
  exit 1
fi

WORKING_DIR=$(realpath -e "${WORKING_DIR}")
if [ "${QUIET}" -eq 1 ]; then
  VERBOSE=0
fi

declare -xr COMMAND="${1}"
declare -xr SECRET_PATH="${2:-'secret/'}"
readonly WORKING_DIR
readonly DRY_RUN
readonly VERBOSE
readonly QUIET

log_verbose "Verbose mode: on"
if [ "${RECURSIVE}" -eq 1 ]; then
  log_verbose "Recursive mode: on"
fi


log_info "Checking for dependencies"
for dependency in "${DEPENDENCIES[@]}"; do
  checkb "${dependency}"
done

case "${COMMAND}" in
  dump)
    log_info "Dumping ${SECRET_PATH} Vault path to ${WORKING_DIR}"
    vault_dump "${SECRET_PATH}" "${WORKING_DIR}"
    ;;
  edit)
    edit "${SECRET_PATH}"
    ;;
  import)
    log_info "Importing ${SECRET_PATH} Vault path from ${WORKING_DIR}"
    vault_import "${SECRET_PATH}" "${WORKING_DIR}"
    ;;
  sync)
    RECURSIVE=1
    log_info "Syncing ${SECRET_PATH} Vault path"
    vault_sync_tree "${SECRET_PATH}"
    ;;
  *)
    log_error "Unknown command: ${COMMAND}"
    exit 1
    ;;
esac

exit 0
