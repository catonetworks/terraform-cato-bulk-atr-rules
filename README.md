# terraform-cato-bulk-atr-rules

Bulk-manages the Cato **App Tenant Restriction (appTenantRestriction)** policy
from a single JSON export: sections and rules (flat policy — no sub-policies
exist for this type), with ordering and publishing via
`cato_bulk_atr_move_rule`.

## Resources managed

| Resource | Keyed by | Notes |
|---|---|---|
| `cato_app_tenant_restriction_section.sections` | `section_name` | created `LAST_IN_POLICY`; ordered by the move resource |
| `cato_app_tenant_restriction_rule.rules` | rule name | placement: managed section → `LAST_IN_SECTION`; sectionless → `LAST_IN_POLICY` |
| `cato_bulk_atr_move_rule.all_atr_rules` | — | orders sections (`section_index`) and rules (`index_in_section`) and **publishes** |

**Publishing:** the rule/section resources save to the draft policy only —
`cato_bulk_atr_move_rule` is the App Tenant Restriction stack's single
publisher. Without it, applies never go live.

## Input JSON

```bash
catocli export atr_rules --json-filename all_atr_rules_and_sections.json
```

Root: `data.policy.appTenantRestriction.policy` with `sections[]`, `rules[]`
(wrappers `{audit, rule, properties}`, ids retained for brownfield import),
and `rules_in_sections[]`. Rule fields: `action` (`BYPASS` | `INJECT_HEADERS`),
`severity`, `application` (single id/name ref), `headers[]` (`{name, value}`,
used with INJECT_HEADERS), `schedule`, `source` (same 14-selector shape as
Application Control, each selector emitted only when non-empty), `enabled`,
`description`.

## Usage

```hcl
module "atr_rules" {
  source                   = "catonetworks/bulk-atr-rules/cato"
  atr_rules_json_file_path = "${path.module}/config_data/all_atr_rules_and_sections.json"
}
```

## Brownfield import

```bash
catocli import atr_rules_to_tf config_data/all_atr_rules_and_sections.json \
  --module-name module.atr_rules --auto-approve
terraform plan   # expect: only cato_bulk_atr_move_rule to add
```

## Known limitations

- Ordering rows with `section_name: ""` are excluded from the move resource
  and surfaced via `unordered_rules`; their order is creation order.
- Run applies with `-parallelism=1` when several module instances share an
  account.
