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
# Layout: .../ansible_collections/infra/<collection> → COLLECTIONS_PATH = parent of ansible_collections
export ANSIBLE_COLLECTIONS_PATH="$(cd "${COLLECTION_ROOT}/../../.." && pwd):${ANSIBLE_COLLECTIONS_PATH:-${HOME}/.ansible/collections:/usr/share/ansible/collections}"

# Exclude obsolete controller_applications (module moved to ansible.platform).
ROUNDTRIP_EXTRA=(
  -e@"${VAULT_A}"
  -e@configs/roundtrip_extra_vars/vaulted_defaults.yml
  -e '{"aap_configuration_dispatcher_exclude_roles":["controller_applications"]}'
)

echo "=== Roundtrip step 1: import seed → AAP ==="
ansible-playbook test_filetree_read.yaml \
  "${ROUNDTRIP_EXTRA[@]}" \
  -e@configs/roundtrip_extra_vars/extra_vars_read.yml \
  --skip-tags custom,fc,fcf,gv \
  --tags "${TAGS}" \
  2>&1 | tee "${LOG_DIR}/step1_import.log"

echo "=== Roundtrip step 2: export AAP → filetree ==="
# Skip yaml_format here: format_yaml needs system PyYAML (python3-yaml) on Ansible's
# module interpreter (user-site packages are often invisible to ansiballz). Export
# files remain valid; run with --tags yaml_format locally once PyYAML is installed.
ansible-playbook test_filetree_create.yaml \
  -e@"${VAULT_A}" \
  -e filetree_ci_keep_output=true \
  -e generate_env_variables_stub=true \
  --tags "always,default" \
  --skip-tags "cleanup,flatten,yaml_format" \
  2>&1 | tee "${LOG_DIR}/step2_export.log"

# Build vaulted_* defaults from the export so re-import can resolve placeholders.
# Stdlib only: Ansible module runs often lack user-site PyYAML; keep harvest independent.
EXPORT_DIR="${FILETREE_OUTPUT_DEFAULT:-/tmp/filetree_output_default}"
VAULTED_FROM_EXPORT="${LOG_DIR}/vaulted_from_export.yml"
python3 - "${EXPORT_DIR}" "${VAULTED_FROM_EXPORT}" "${VAULT_A}" <<'PY'
import re, sys, pathlib
export_dir, out_path, vault_path = map(pathlib.Path, sys.argv[1:4])

def yaml_scalar(value: str) -> str:
    if value == "" or any(c in value for c in ":#{}[]&*!|>'\"%@`\n") or value != value.strip():
        return "'" + value.replace("'", "''") + "'"
    return value

admin_pw = "roundtrip"
if vault_path.is_file():
    match = re.search(
        r"^vault_aap_password:\s*(?:'([^']*)'|\"([^\"]*)\"|(\S+))",
        vault_path.read_text(errors="ignore"),
        re.M,
    )
    if match:
        admin_pw = next(g for g in match.groups() if g is not None)

names = set()
for path in export_dir.rglob("*"):
    if path.is_file() and path.suffix in {".yml", ".yaml"}:
        try:
            text = path.read_text(errors="ignore")
        except OSError:
            continue
        names.update(re.findall(r"\bvaulted_[a-z0-9_]+\b", text))

lines = []
for name in sorted(names):
    if name.endswith("_admin_password") or name == "vaulted_gateway_users_admin_password":
        val = admin_pw
    else:
        val = "roundtrip"
    lines.append(f"{name}: {yaml_scalar(val)}")
out_path.write_text("\n".join(lines) + ("\n" if lines else ""))
print(f"Wrote {len(names)} vaulted defaults to {out_path}")
PY

echo "=== Roundtrip step 3: re-import export → AAP ==="
ansible-playbook test_filetree_read.yaml \
  "${ROUNDTRIP_EXTRA[@]}" \
  -e@"${VAULTED_FROM_EXPORT}" \
  -e@configs/roundtrip_extra_vars/extra_vars_read_export.yml \
  --skip-tags custom,fc,fcf,gv \
  --tags "${TAGS}" \
  2>&1 | tee "${LOG_DIR}/step3_reimport.log"

echo "=== Roundtrip complete (logs under ${LOG_DIR}) ==="
