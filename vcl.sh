#!/bin/bash

set -e

PARAM="${1}"
vault_path=${2:-'secret/'}

if [ $# -ne 1 ]
then
  echo "Usage:"
  echo "$0 get-all"
  echo "$0 get-all secret/bar/"
  echo "$0 edit secret/foo"
  echo "$0 push secret/foo"
  exit 1
fi

lst_bin_to_check=(mkdir vault jq vim)

function checkb {
  local bin=$1
  [ -f "$(which ${bin})" ] >/dev/null 2>&1 || \
    { echo "Please install ${bin}"; exit $NOT_OK ;};
}

for inp in "${lst_bin_to_check[@]}";do
  checkb "${inp}"
done

function getAll {
  local path="${1}"
  for i in `vault list "${path}" | grep -Ev 'Ke|----|^$'`;
  do
    if [ "${i: -1}" == '/' ]; then
      new_path="${path}${i}"
      mkdir -p "${new_path}"
      getAll "${new_path}"
    else
      vault read --format=json "${path}${i}" | jq '.data' > "${path}${i}".json
    fi
  done
}

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
    echo "Error, pass vaild sorce and destination path:"
    echo "${src} - ${dst}"
  fi
}

function edit {
  local path="${1}"
  if [ "${path: -1}" == '/' ]; then
    echo "Error, pass vaild secret path: ${path}"
  else
    vim ${path}
  fi
}

function push {
  local path="${1}"
  if [ "${path: -1}" == '/' ]; then
    echo "Error, pass vaild secret path: ${path}"
  else
    vault write ${path} @"${path}".json
  fi
}

case "$PARAM" in
  get-all )
    getAll "${vault_path}"
    ;;
  edit )
    edit "${vault_path}"
    ;;
  push )
    push "${vault_path}"
    ;;
  *)
    echo "Unknown argument: $PARAM "
    exit 1
    ;;
esac

exit 0
