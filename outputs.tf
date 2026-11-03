output "deployment_summary" {
  description = "Counts of managed App Tenant Restriction objects."
  value = {
    sections = length(cato_app_tenant_restriction_section.sections)
    rules    = length(cato_app_tenant_restriction_rule.rules)
  }
}

output "section_ids" {
  description = "Map of section name to section id."
  value       = { for name, s in cato_app_tenant_restriction_section.sections : name => s.id }
}

output "rule_ids" {
  description = "Map of rule name to rule id."
  value       = { for name, r in cato_app_tenant_restriction_rule.rules : name => r.id }
}

output "unordered_rules" {
  description = "rules_in_sections rows excluded from cato_bulk_atr_move_rule (no managed section to order within)."
  value       = local.unordered_rules_data
}
