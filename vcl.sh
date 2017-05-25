#!/bin/bash


vault_path=${1:-'secret/'}

function getAll {
  path="${1}"
  for i in `vault list "${path}" | grep -Ev 'Ke|-|^$'`;
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

getAll "${vault_path}"
