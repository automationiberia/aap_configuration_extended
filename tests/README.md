# Collection tests

Integration and regression playbooks for `infra.aap_configuration_extended`.

## AAP connection (two external instances)

Copy the examples and fill in real values (files are gitignored):

```bash
cp tests/vault-aap-a.yaml.example tests/vault-aap-a.yaml
cp tests/vault-aap-b.yaml.example tests/vault-aap-b.yaml
```

| File | Role |
| ---- | ---- |
| `vault-aap-a.yaml` | Instance A — roundtrip / regression / PRE (source) |
| `vault-aap-b.yaml` | Instance B — dual-instance / PRO (target) |
| `vault-aap-controller.yaml` | Legacy alias; still accepted if A is missing |

Shape:

```yaml
vault_aap_hostname: "aap-a.example.com"
vault_aap_username: "admin"
vault_aap_password: "CHANGE_ME"
vault_aap_validate_certs: false
```

Run playbooks from `tests/` so `tests/ansible.cfg` applies (`inject_facts_as_vars = false`).

## Regression runner (optional pre-commit)

```bash
# Offline only (unit + syntax-check)
REGRESSION_TIERS=offline bash tests/scripts/run-regression.sh

# All tiers (skips live if vaults missing)
bash tests/scripts/run-regression.sh

# Via pre-commit (manual stage — not on default commit)
pre-commit run aap-regression --hook-stage manual
REGRESSION_TIERS=offline pre-commit run aap-regression --hook-stage manual
```

| Tier | What it runs | Requires |
| ---- | ------------ | -------- |
| `offline` | `tests/unit/`, env stub, syntax-check | nothing |
| `live-a` | kerberos, gateway RBAC, roundtrip | `vault-aap-a.yaml` |
| `live-ab` | token smoke A+B; optional JT/WFJT export A→import B | A + B vaults |
| `filetree-object-diff` | offline (+ live if vault A) | plugins on branch |

Useful env vars:

- `REGRESSION_SKIP_ROUNDTRIP=1` — skip full roundtrip in `live-a`
- `REGRESSION_SKIP_KERBEROS=1` / `REGRESSION_SKIP_GATEWAY=1` — skip targeted live checks
- `REGRESSION_JT_NAME` / `REGRESSION_WFJT_NAME` — enable dual-instance related export smoke
- `REGRESSION_REQUIRE_LIVE=1` — fail instead of skip when vaults are missing
- `REGRESSION_RUN_CI_SEED=1` — also run `ci_seed_aap24_dispatch.yml`

Roundtrip alone:

```bash
bash tests/scripts/run-roundtrip.sh
```

See also `.cursor/skills/filetree-roundtrip-test/SKILL.md`.
