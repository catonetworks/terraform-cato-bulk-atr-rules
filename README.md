# Terraform Cato Bulk App Tenant Restriction Rules Module

> [!IMPORTANT]
> This module targets the Cato Terraform provider `2.0.0` (general
> availability). Ensure your configuration resolves provider `2.0.0` or newer.


This module allows you to bulk import App Tenant Restriction (ATR) rules and sections from a JSON configuration file, and define the order of those rules and sections within the Cato policy.

## Usage

The module reads a JSON configuration file that defines:
- **Rules**: Individual App Tenant Restriction rules with their configurations
- **Sections**: Logical groupings for organizing rules
- **Rule ordering**: Defines which rules belong to which sections and their order within sections

### Basic Example

```hcl
module "atr_rules" {
  source = "catonetworks/bulk-atr-rules/cato"

  atr_rules_json_file_path = "./config_data/all_atr_rules_and_sections.json"
}
```

### JSON Configuration Structure

The JSON file should contain a nested structure with the following key components:

- `data.policy.appTenantRestriction.policy.rules[]` - Array of App Tenant Restriction rules
- `data.policy.appTenantRestriction.policy.sections[]` - Array of sections with index and name
- `data.policy.appTenantRestriction.policy.rules_in_sections[]` - Mapping of rules to sections with ordering

App Tenant Restriction is a **flat policy** — there is no sub-policy concept for this rule type, unlike Internet Firewall or WAN Firewall.

#### Key Fields:

**Rules Array**: Each rule entry is wrapped as `{audit, rule, properties}` (ids retained on the `rule` object for brownfield import). The `rule` object carries: `name`, `description`, `enabled`, `action` (`BYPASS` | `INJECT_HEADERS`), `severity`, `application` (single id/name reference), `headers[]` (`{name, value}`, used with `INJECT_HEADERS`), `schedule`, and `source`.

**Sections Array**: Defines sections with:
- `section_index`: The order of the section in the policy
- `section_name`: The display name of the section

**Rules in Sections Array**: Maps rules to sections with:
- `index_in_section`: The order of the rule within its section
- `section_name`: The section this rule belongs to
- `rule_name`: The name of the rule to place in the section

<details>
<summary>Click to expand full JSON configuration example</summary>

```json
{
  "data": {
    "policy": {
      "appTenantRestriction": {
        "policy": {
          "enabled": true,
          "rules": [
            {
              "audit": {},
              "properties": [],
              "rule": {
                "id": "12345",
                "name": "My ATR Rule 1",
                "description": "Bypass restriction for a trusted SaaS app",
                "enabled": true,
                "action": "BYPASS",
                "severity": "MEDIUM",
                "application": {
                  "name": "Salesforce"
                },
                "source": {
                  "group": [
                    { "name": "Sales Team" }
                  ]
                },
                "section": {
                  "name": "My ATR Section 1"
                }
              }
            },
            {
              "audit": {},
              "properties": [],
              "rule": {
                "id": "12346",
                "name": "My ATR Rule 2",
                "description": "Inject tenant header for approved tenant",
                "enabled": true,
                "action": "INJECT_HEADERS",
                "severity": "LOW",
                "application": {
                  "name": "Microsoft 365"
                },
                "headers": [
                  { "name": "X-Tenant-Id", "value": "contoso.onmicrosoft.com" }
                ],
                "source": {},
                "section": {
                  "name": "My ATR Section 2"
                }
              }
            }
          ],
          "sections": [
            {
              "section_index": 1,
              "section_name": "My ATR Section 1"
            },
            {
              "section_index": 2,
              "section_name": "My ATR Section 2"
            }
          ],
          "rules_in_sections": [
            {
              "index_in_section": 1,
              "section_name": "My ATR Section 1",
              "rule_name": "My ATR Rule 1"
            },
            {
              "index_in_section": 1,
              "section_name": "My ATR Section 2",
              "rule_name": "My ATR Rule 2"
            }
          ]
        }
      }
    }
  }
}
```
</details>

### How Rule Ordering Works

Based on the example above:
1. **Section 1** ("My ATR Section 1") is created first
2. **Section 2** ("My ATR Section 2") is created second
3. **Rule 1** is placed in Section 1 at position 1
4. **Rule 2** is placed in Section 2 at position 1

The final policy structure will be:
```
├── My ATR Section 1
│   └── My ATR Rule 1
└── My ATR Section 2
    └── My ATR Rule 2
```

`cato_bulk_atr_move_rule` applies this ordering and **publishes** the policy —
the section/rule resources only save to the draft; without the move resource,
applies never go live.

`rules_in_sections` rows whose `section_name` is `""` (no section) are
excluded from the move resource and surfaced via the `unordered_rules`
output; their order is creation order only.

### Parameters

- `atr_rules_json_file_path`: Path to your JSON configuration file (`data.policy.appTenantRestriction.policy` root)
- `policy_enabled`: (Optional, default `null`) Account-level policy toggle. `null` leaves it unmanaged (resource not created); `true`/`false` manages it via `cato_app_tenant_restriction_policy`.
- `allow_empty_policy`: (Optional) Safety guard — fail planning when the policy JSON contains 0 rules unless explicitly allowed. Default `false`.

## Working with Existing Rules (Brownfield Deployments)

For brownfield deployments where you have existing App Tenant Restriction rules in your Cato Management Application, you can use the Cato CLI to export and import these rules into Terraform state.

### Installing and Configuring Cato CLI

1. **Install the Cato CLI:**
   ```bash
   pip3 install catocli
   ```

2. **Configure the CLI with your Cato credentials:**
   ```bash
   catocli configure set
   ```
   This will prompt you for your Cato Management Application credentials and account information.

### Exporting Existing Rules

To export your existing App Tenant Restriction rules and sections into the JSON format required by this module:

```bash
catocli export atr_rules --json-filename all_atr_rules_and_sections.json
```

This command will generate a JSON file containing all your existing ATR rules and sections in the correct format for this Terraform module.

### Importing Existing Rules into Terraform State (native import blocks)

Once you have the JSON configuration file, you can adopt the existing rules and sections into Terraform state. This is useful for:

- **Brownfield deployments**: Managing existing rules with Terraform
- **Backup and restore**: Restoring rules to a known good state after unintended changes
- **State management**: Bringing existing infrastructure under Terraform control

There are two ways to do this. All of this module's `for_each` state addresses are keyed by name (rule name, section name), which is exactly what lets both options below line up directly against the exported JSON.

<details>
<summary>Option A (recommended) — native Terraform import blocks (migration.tf)</summary>

Requires Terraform >= 1.7. Create a one-shot `migration.tf` file beside your module call with one `import` block per resource type:

```hcl
# migration.tf — one-shot; delete after a successful `terraform apply` adopts
# the existing rules/sections into state.

locals {
  migrate_json     = jsondecode(file("${path.module}/config_data/all_atr_rules_and_sections.json"))
  migrate_policy   = local.migrate_json.data.policy.appTenantRestriction.policy
  migrate_sections = { for s in local.migrate_policy.sections : s.section_name => s.section_id }
  migrate_rules    = { for rw in local.migrate_policy.rules : rw.rule.name => rw.rule.id }
}

import {
  for_each = local.migrate_sections
  to       = module.atr_rules.cato_app_tenant_restriction_section.sections[each.key]
  id       = each.value
}

import {
  for_each = local.migrate_rules
  to       = module.atr_rules.cato_app_tenant_restriction_rule.rules[each.key]
  id       = each.value
}
```

Note: the provider also has an importable `cato_app_tenant_restriction_policy`
singleton toggle, but this module doesn't wire that resource into `main.tf`
(see "Resources managed" below), so there's nothing to import for it here.

Preview the adoption before anything touches state:

```bash
terraform plan
```

Expect `N to import, 1 to add, 0 to change, 0 to destroy`. The "1 to add" is
expected — it's `cato_bulk_atr_move_rule.all_atr_rules`, which **cannot be
imported** (the provider implements no `ImportState` for it; it's a
plan-time ordering/publish resource with no independent API identity of its
own) and is always created fresh on the first apply after an import. Any
*other* "to change" means the JSON export is stale relative to the live
policy — **re-export** (`catocli export atr_rules`) and regenerate the
locals above, rather than letting `terraform apply` overwrite the live
policy with stale config.

Once the plan is clean, adopt the resources into state:

```bash
terraform apply
```

This adopts the sections and rules into state (and creates the move/publish
resource, republishing once — a harmless no-op since content already
matches live policy). Then delete `migration.tf` — its job is done, and
leaving it in place just re-runs the same (no-op) import blocks on every
future plan.

</details>

<details>
<summary>Option B — catocli import atr_rules_to_tf (imperative alternative)</summary>

An imperative alternative to Option A, for when native import blocks aren't practical (e.g. scripting a fully automated onboarding pipeline). Unlike Option A, this mutates Terraform state immediately — there is no plan preview before the import happens.

```bash
catocli import atr_rules_to_tf config_data/all_atr_rules_and_sections.json \
  --module-name module.atr_rules --auto-approve
```

**Parameters:**
- `config_data/all_atr_rules_and_sections.json`: Path to your exported JSON file
- `--module-name module.atr_rules`: The name of your Terraform module instance

```bash
terraform plan   # expect: only cato_bulk_atr_move_rule to add
```

</details>

### Typical Brownfield Workflow

1. **Export existing rules:**
   ```bash
   catocli export atr_rules --json-filename all_atr_rules_and_sections.json
   ```

2. **Create your Terraform configuration:**
   ```hcl
   module "atr_rules" {
     source = "catonetworks/bulk-atr-rules/cato"

     atr_rules_json_file_path = "./config_data/all_atr_rules_and_sections.json"
   }
   ```

3. **Adopt existing state (Option A — recommended):** create `migration.tf` with the import blocks shown above, then:
   ```bash
   terraform plan    # preview: expect only "to import" (plus the move resource "to add")
   terraform apply   # adopt into state
   ```
   Delete `migration.tf` afterwards. (Option B: `catocli import atr_rules_to_tf config_data/all_atr_rules_and_sections.json --module-name module.atr_rules` — imperative, no plan preview.)

4. **Run Terraform plan to verify:**
   ```bash
   terraform plan
   ```
   This should show no changes if the import was successful.

### Backup and Restore Workflow

If unintended changes are made directly to rules and sections in the Cato Management Application, you can restore to the last known good state:

1. **Apply your last known good configuration:**
   ```bash
   terraform apply
   ```
   This will restore rules and sections to match your Terraform configuration.

2. **Alternatively, re-export and compare:**
   ```bash
   catocli export atr_rules --json-filename all_atr_rules_and_sections.json
   # Compare with your existing JSON file to identify changes
   ```

## Known Limitations

- Ordering rows with `section_name: ""` are excluded from
  `cato_bulk_atr_move_rule` and surfaced via the `unordered_rules` output;
  their order is creation order only.
- Run applies with `-parallelism=1` when several module instances share an
  account.

## Using Module Outputs

The module provides outputs that can be used for monitoring, auditing, integration with other systems, and operational insights. Below are practical examples of how to use these outputs in your Terraform configuration.

<details>
<summary>Click to expand example client-side outputs</summary>

```hcl
# Basic deployment information
output "deployment_info" {
  description = "Basic information about the App Tenant Restriction deployment"
  value = {
    total_sections = module.atr_rules.deployment_summary.sections
    total_rules    = module.atr_rules.deployment_summary.rules
  }
}

# Quick reference for rule and section IDs
output "quick_reference" {
  description = "Quick reference maps for rules and sections"
  value = {
    section_ids = module.atr_rules.section_ids
    rule_ids    = module.atr_rules.rule_ids
  }
}

# Example: For integration with monitoring systems
output "monitoring_metrics" {
  description = "Example metrics that could be sent to monitoring systems"
  value = {
    deployment_timestamp = timestamp()
    total_atr_rules      = module.atr_rules.deployment_summary.rules
    total_atr_sections   = module.atr_rules.deployment_summary.sections
  }
}

# Example: Rules that need attention (unordered)
output "rules_needing_attention" {
  description = "Example of identifying rules that couldn't be ordered"
  value = {
    unordered_rules       = module.atr_rules.unordered_rules
    unordered_rules_count = length(module.atr_rules.unordered_rules)
  }
}

# Example: For audit and compliance reporting
output "audit_report" {
  description = "Example audit report using module outputs"
  value = {
    deployment_summary = {
      date              = timestamp()
      sections_deployed = module.atr_rules.deployment_summary.sections
      rules_deployed    = module.atr_rules.deployment_summary.rules
    }
    section_ids_map = module.atr_rules.section_ids
    rule_ids_map    = module.atr_rules.rule_ids
    unordered_rules = module.atr_rules.unordered_rules
  }
}
```
</details>

### Output Use Cases

These example outputs demonstrate various practical applications:

- **`deployment_info`**: Quick deployment overview for dashboards
- **`quick_reference`**: ID mappings for referencing resources in other modules
- **`monitoring_metrics`**: Metrics formatted for monitoring systems
- **`rules_needing_attention`**: Identifying rules excluded from ordering for review
- **`audit_report`**: Comprehensive audit trail for compliance

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_cato"></a> [cato](#requirement\_cato) | >= 2.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cato"></a> [cato](#provider\_cato) | >= 2.0.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [cato_app_tenant_restriction_rule.rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/app_tenant_restriction_rule) | resource |
| [cato_app_tenant_restriction_section.sections](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/app_tenant_restriction_section) | resource |
| [cato_bulk_atr_move_rule.all_atr_rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/bulk_atr_move_rule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allow_empty_policy"></a> [allow\_empty\_policy](#input\_allow\_empty\_policy) | Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown. | `bool` | `false` | no |
| <a name="input_policy_enabled"></a> [policy\_enabled](#input\_policy\_enabled) | Manage the account-level App Tenant Restriction policy toggle. null leaves the toggle unmanaged; true/false manages it via cato\_app\_tenant\_restriction\_policy. | `bool` | `null` | no |
| <a name="input_atr_rules_json_file_path"></a> [atr\_rules\_json\_file\_path](#input\_atr\_rules\_json\_file\_path) | Path to the App Tenant Restriction JSON export produced by `catocli export atr_rules` (data.policy.appTenantRestriction.policy root). | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_deployment_summary"></a> [deployment\_summary](#output\_deployment\_summary) | Counts of managed App Tenant Restriction objects. |
| <a name="output_rule_ids"></a> [rule\_ids](#output\_rule\_ids) | Map of rule name to rule id. |
| <a name="output_section_ids"></a> [section\_ids](#output\_section\_ids) | Map of section name to section id. |
| <a name="output_unordered_rules"></a> [unordered\_rules](#output\_unordered\_rules) | rules\_in\_sections rows excluded from cato\_bulk\_atr\_move\_rule (no managed section to order within). |
<!-- END_TF_DOCS -->
