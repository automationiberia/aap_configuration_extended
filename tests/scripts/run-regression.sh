#!/usr/bin/env bash
# Optional AAP regression suite for local / pre-commit (manual stage).
#
# Tiers (REGRESSION_TIERS, comma-separated; default: all):
#   offline              — unit + stub + syntax-check (always runnable)
#   live-a               — live tests against vault-aap-a.yaml
#   live-ab              — dual-instance smoke (A + B vaults)
#   filetree-object-diff — gated on filetree_cac_diff plugin + vault A
#   all                  — expand to offline,live-a,live-ab,filetree-object-diff
#
# Missing vaults / plugins → tier skipped (exit 0 for that tier) unless
# REGRESSION_REQUIRE_LIVE=1 (then missing vault fails).
#
# Examples:
#   bash tests/scripts/run-regression.sh
#   REGRESSION_TIERS=offline bash tests/scripts/run-regression.sh
#   pre-commit run aap-regression --hook-stage manual
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COLLECTION_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

cd "${COLLECTION_ROOT}"
export ANSIBLE_CONFIG="${TESTS_DIR}/ansible.cfg"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-/tmp/ansible-local-regression}"
export ANSIBLE_REMOTE_TEMP="${ANSIBLE_REMOTE_TEMP:-/tmp/ansible-remote-regression}"
# Prefer this workspace checkout over any older install under ~/.ansible/collections
# Layout: .../ansible_collections/infra/<collection> → COLLECTIONS_PATH = parent of ansible_collections
export ANSIBLE_COLLECTIONS_PATH="$(cd "${COLLECTION_ROOT}/../../.." && pwd):${ANSIBLE_COLLECTIONS_PATH:-${HOME}/.ansible/collections:/usr/share/ansible/collections}"
mkdir -p "${ANSIBLE_LOCAL_TEMP}" "${ANSIBLE_REMOTE_TEMP}"

VAULT_A="${VAULT_A:-${TESTS_DIR}/vault-aap-a.yaml}"
VAULT_B="${VAULT_B:-${TESTS_DIR}/vault-aap-b.yaml}"
LEGACY_VAULT="${TESTS_DIR}/vault-aap-controller.yaml"

if [[ ! -f "${VAULT_A}" && -f "${LEGACY_VAULT}" ]]; then
  VAULT_A="${LEGACY_VAULT}"
fi

TIERS_RAW="${REGRESSION_TIERS:-all}"
if [[ "${TIERS_RAW}" == "all" ]]; then
  TIERS_RAW="offline,live-a,live-ab,filetree-object-diff"
fi

IFS=',' read -r -a TIERS <<< "${TIERS_RAW}"

has_tier() {
  local want="$1"
  local t
  for t in "${TIERS[@]}"; do
    if [[ "${t// /}" == "${want}" ]]; then
      return 0
    fi
  done
  return 1
}

skip_msg() {
  echo "SKIP: $*"
}

fail_or_skip_vault() {
  local which="$1"
  local path="$2"
  if [[ -f "${path}" ]]; then
    return 0
  fi
  if [[ "${REGRESSION_REQUIRE_LIVE:-0}" == "1" ]]; then
    echo "ERROR: required vault missing: ${path}" >&2
    exit 1
  fi
  skip_msg "${which} (${path} not found; copy from ${which}.example)"
  return 1
}

has_filetree_object_diff_plugins() {
  [[ -f "${COLLECTION_ROOT}/plugins/modules/filetree_cac_diff.py" ]] \
    || [[ -f "${COLLECTION_ROOT}/plugins/lookup/controller_filetree_diff.py" ]] \
    || [[ -d "${COLLECTION_ROOT}/roles/filetree_object_diff" ]]
}

run_offline() {
  echo "=== Tier: offline ==="

  if [[ -f "${TESTS_DIR}/unit/test_filetree_vars.py" ]]; then
    echo "--- unittest: filetree_vars ---"
    python3 -m unittest discover -s "${TESTS_DIR}/unit" -p 'test_*.py' -v
  else
    skip_msg "unit tests not present"
  fi

  if [[ -f "${TESTS_DIR}/test_env_variables_stub.yml" ]]; then
    echo "--- playbook: test_env_variables_stub.yml ---"
    ansible-playbook "${TESTS_DIR}/test_env_variables_stub.yml" -i localhost,
  fi

  local pb
  for pb in \
    playbooks/export_job_template_related.yml \
    playbooks/export_workflow_job_template_related.yml \
    playbooks/import_filetree.yml \
    tests/test_filetree_create.yaml \
    tests/test_filetree_read.yaml \
    tests/test_kerberos_credential_type_export.yaml \
    tests/test_gateway_role_user_assignments_resolve.yaml \
    tests/prepare_aap_origin.yml \
    tests/ci_seed_aap24_dispatch.yml \
    tests/ci_filetree_read_exported.yml
  do
    if [[ -f "${COLLECTION_ROOT}/${pb}" ]]; then
      echo "--- syntax-check: ${pb} ---"
      ansible-playbook --syntax-check "${COLLECTION_ROOT}/${pb}" -i localhost,
    fi
  done

  echo "=== Tier offline: OK ==="
}

run_live_a() {
  echo "=== Tier: live-a ==="
  if ! fail_or_skip_vault "vault-aap-a.yaml" "${VAULT_A}"; then
    return 0
  fi

  cd "${TESTS_DIR}"

  if [[ "${REGRESSION_SKIP_PREPARE:-0}" != "1" ]]; then
    echo "--- prepare AAP origin (minimal objects) ---"
    ansible-playbook prepare_aap_origin.yml -e@"${VAULT_A}"
  else
    skip_msg "prepare_aap_origin (REGRESSION_SKIP_PREPARE=1)"
  fi

  if [[ -f test_kerberos_credential_type_export.yaml ]]; then
    if [[ "${REGRESSION_SKIP_KERBEROS:-0}" == "1" ]]; then
      skip_msg "kerberos (REGRESSION_SKIP_KERBEROS=1)"
    else
      echo "--- kerberos credential type export ---"
      ansible-playbook test_kerberos_credential_type_export.yaml -e@"${VAULT_A}"
    fi
  fi

  if [[ -f test_gateway_role_user_assignments_resolve.yaml ]]; then
    if [[ "${REGRESSION_SKIP_GATEWAY:-0}" == "1" ]]; then
      skip_msg "gateway RBAC (REGRESSION_SKIP_GATEWAY=1)"
    else
      echo "--- gateway role user assignments resolve ---"
      ansible-playbook test_gateway_role_user_assignments_resolve.yaml -e@"${VAULT_A}"
    fi
  fi

  if [[ -f test_object_diff.yaml ]]; then
    echo "--- object_diff (legacy) ---"
    ansible-playbook test_object_diff.yaml -e@"${VAULT_A}" || {
      echo "WARN: test_object_diff.yaml failed or needs extra vars; continuing if ROUNDTRIP is primary" >&2
      if [[ "${REGRESSION_STRICT_OBJECT_DIFF:-0}" == "1" ]]; then
        exit 1
      fi
    }
  fi

  if [[ "${REGRESSION_SKIP_ROUNDTRIP:-0}" != "1" ]]; then
    echo "--- full roundtrip ---"
    bash "${SCRIPT_DIR}/run-roundtrip.sh"
  else
    skip_msg "roundtrip (REGRESSION_SKIP_ROUNDTRIP=1)"
  fi

  if [[ "${REGRESSION_RUN_CI_SEED:-0}" == "1" ]]; then
    echo "--- ci_seed_aap24_dispatch ---"
    ansible-playbook ci_seed_aap24_dispatch.yml -e@"${VAULT_A}"
  fi

  echo "=== Tier live-a: OK ==="
}

run_live_ab() {
  echo "=== Tier: live-ab ==="
  local ok=1
  fail_or_skip_vault "vault-aap-a.yaml" "${VAULT_A}" || ok=0
  fail_or_skip_vault "vault-aap-b.yaml" "${VAULT_B}" || ok=0
  if [[ "${ok}" != "1" ]]; then
    return 0
  fi

  cd "${TESTS_DIR}"

  echo "--- connectivity smoke: token on A ---"
  ansible-playbook test_filetree_create.yaml \
    -e@"${VAULT_A}" \
    --tags always \
    --skip-tags default,flatten,cleanup,yaml_format \
    2>&1 | tee /tmp/regression_live_a_token.log | tail -20

  echo "--- connectivity smoke: token on B ---"
  ansible-playbook test_filetree_create.yaml \
    -e@"${VAULT_B}" \
    --tags always \
    --skip-tags default,flatten,cleanup,yaml_format \
    2>&1 | tee /tmp/regression_live_b_token.log | tail -20

  if [[ -n "${REGRESSION_JT_NAME:-}" ]]; then
    echo "--- JT related export A → import B (job_template_name=${REGRESSION_JT_NAME}) ---"
    local out_dir="/tmp/regression_jt_related_export"
    rm -rf "${out_dir}"
    mkdir -p "${out_dir}"
    # JSON -e required so names with spaces are not truncated
    ansible-playbook "${COLLECTION_ROOT}/playbooks/export_job_template_related.yml" \
      -e@"${VAULT_A}" \
      -e "{\"job_template_name\":\"${REGRESSION_JT_NAME}\"}" \
      -e "output_path=${out_dir}"
    ansible-playbook "${COLLECTION_ROOT}/playbooks/import_filetree.yml" \
      -e@"${VAULT_B}" \
      -e "dir_orgs_vars=${out_dir}" \
      -e "filetree_create_layout=true"
  else
    skip_msg "JT related dual smoke (set REGRESSION_JT_NAME to enable)"
  fi

  if [[ -n "${REGRESSION_WFJT_NAME:-}" ]]; then
    echo "--- WFJT related export A → import B (workflow_job_template_name=${REGRESSION_WFJT_NAME}) ---"
    local out_dir_wf="/tmp/regression_wfjt_related_export"
    rm -rf "${out_dir_wf}"
    mkdir -p "${out_dir_wf}"
    ansible-playbook "${COLLECTION_ROOT}/playbooks/export_workflow_job_template_related.yml" \
      -e@"${VAULT_A}" \
      -e "{\"workflow_job_template_name\":\"${REGRESSION_WFJT_NAME}\"}" \
      -e "output_path=${out_dir_wf}"
    ansible-playbook "${COLLECTION_ROOT}/playbooks/import_filetree.yml" \
      -e@"${VAULT_B}" \
      -e "dir_orgs_vars=${out_dir_wf}" \
      -e "filetree_create_layout=true"
  else
    skip_msg "WFJT related dual smoke (set REGRESSION_WFJT_NAME to enable)"
  fi

  echo "=== Tier live-ab: OK ==="
}

run_filetree_object_diff() {
  echo "=== Tier: filetree-object-diff ==="
  if ! has_filetree_object_diff_plugins; then
    skip_msg "filetree_object_diff plugins/role not present on this branch"
    return 0
  fi

  echo "--- offline cac_diff / lookup ---"
  bash "${SCRIPT_DIR}/run-filetree-object-diff-full-test.sh"

  if fail_or_skip_vault "vault-aap-a.yaml" "${VAULT_A}"; then
    echo "--- live filetree_object_diff full ---"
    RUN_LIVE_TESTS=1 bash "${SCRIPT_DIR}/run-filetree-object-diff-full-test.sh" -e@"${VAULT_A}"
  fi

  echo "=== Tier filetree-object-diff: OK ==="
}

echo "Regression tiers: ${TIERS_RAW}"
echo "Collection root: ${COLLECTION_ROOT}"

if has_tier offline; then
  run_offline
fi
if has_tier live-a; then
  run_live_a
fi
if has_tier live-ab; then
  run_live_ab
fi
if has_tier filetree-object-diff; then
  run_filetree_object_diff
fi

echo "=== Regression suite finished ==="
