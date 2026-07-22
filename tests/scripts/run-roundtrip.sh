#!/usr/bin/env bash
# Full filetree import → export → re-import roundtrip against instance A.
# See .cursor/skills/filetree-roundtrip-test/SKILL.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COLLECTION_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

VAULT_A="${VAULT_A:-${TESTS_DIR}/vault-aap-a.yaml}"
if [[ ! -f "${VAULT_A}" ]]; then
  # Legacy alias
  if [[ -f "${TESTS_DIR}/vault-aap-controller.yaml" ]]; then
    VAULT_A="${TESTS_DIR}/vault-aap-controller.yaml"
  else
    echo "ERROR: missing ${TESTS_DIR}/vault-aap-a.yaml (copy from vault-aap-a.yaml.example)" >&2
    exit 1
  fi
fi

TAGS="$(tr -d '\n' < "${TESTS_DIR}/configs/roundtrip/ansible_tags")"
LOG_DIR="${ROUNDTRIP_LOG_DIR:-/tmp/filetree_roundtrip_test}"
mkdir -p "${LOG_DIR}/input" "${LOG_DIR}/export"

echo "=== Roundtrip: prepare seed ==="
rm -rf /tmp/filetree_roundtrip_test
mkdir -p /tmp/filetree_roundtrip_test/input /tmp/filetree_roundtrip_test/export
cp -a "${TESTS_DIR}/configs/roundtrip/"* /tmp/filetree_roundtrip_test/input/

cd "${TESTS_DIR}"
export ANSIBLE_CONFIG="${TESTS_DIR}/ansible.cfg"

echo "=== Roundtrip step 1: import seed → AAP ==="
ansible-playbook test_filetree_read.yaml \
  -e@"${VAULT_A}" \
  -e@configs/roundtrip_extra_vars/extra_vars_read.yml \
  --skip-tags custom,fc,fcf,gv \
  --tags "${TAGS}" \
  2>&1 | tee "${LOG_DIR}/step1_import.log"

echo "=== Roundtrip step 2: export AAP → filetree ==="
ansible-playbook test_filetree_create.yaml \
  -e@"${VAULT_A}" \
  -e filetree_ci_keep_output=true \
  --tags "always,default,yaml_format" \
  --skip-tags "cleanup,flatten" \
  2>&1 | tee "${LOG_DIR}/step2_export.log"

echo "=== Roundtrip step 3: re-import export → AAP ==="
ansible-playbook test_filetree_read.yaml \
  -e@"${VAULT_A}" \
  -e@configs/roundtrip_extra_vars/extra_vars_read_export.yml \
  --skip-tags custom,fc,fcf,gv \
  --tags "${TAGS}" \
  2>&1 | tee "${LOG_DIR}/step3_reimport.log"

echo "=== Roundtrip complete (logs under ${LOG_DIR}) ==="
