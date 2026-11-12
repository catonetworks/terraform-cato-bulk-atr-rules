# terraform-cato-bulk-atr-rules
#
# Bulk-manages the Cato App Tenant Restriction (appTenantRestriction) policy
# from one JSON export produced by `catocli export atr_rules`:
#   sections[] / rules[] / rules_in_sections[] - flat policy, no sub-policies.
# cato_bulk_atr_move_rule applies ordering and republishes.

locals {
  atr_json = jsondecode(file("${var.atr_rules_json_file_path}"))
  atr      = local.atr_json.data.policy.appTenantRestriction.policy

  sections_data_raw      = try(local.atr.sections, [])
  rules_data_raw         = try(local.atr.rules, [])
  rules_in_sections_data = try(local.atr.rules_in_sections, [])

  sections_data = {
    for s in local.sections_data_raw : s.section_name => s
  }

  rules_by_name = {
    for rw in local.rules_data_raw : rw.rule.name => rw
  }

  move_section_data = {
    for name, s in local.sections_data : name => {
      section_index = s.section_index
    }
  }

  move_rule_data = {
    for row in local.rules_in_sections_data :
    row.rule_name => {
      index_in_section = row.index_in_section
      section_name     = row.section_name
    }
    if row.section_name != "" && contains(keys(local.sections_data), row.section_name)
  }

  unordered_rules_data = [
    for row in local.rules_in_sections_data : row
    if !contains(keys(local.move_rule_data), try(row.rule_name, ""))
  ]

  # Source selector translation (same shape as Application Control sources).
  atr_source_bodies = {
    for name, rw in local.rules_by_name : name => merge(
      try(length(rw.rule.source.country), 0) > 0 ? { country = [for x in rw.rule.source.country : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(rw.rule.source.ip), 0) > 0 ? { ip = rw.rule.source.ip } : {},
      try(length(rw.rule.source.host), 0) > 0 ? { host = [for x in rw.rule.source.host : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(rw.rule.source.site), 0) > 0 ? { site = [for x in rw.rule.source.site : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(rw.rule.source.subnet), 0) > 0 ? { subnet = rw.rule.source.subnet } : {},
      try(length(rw.rule.source.ipRange), 0) > 0 ? { ip_range = [for r in rw.rule.source.ipRange : { from = r.from, to = r.to }] } : {},
      try(length(rw.rule.source.globalIpRange), 0) > 0 ? { global_ip_range = [for x in rw.rule.source.globalIpRange : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(rw.rule.source.networkInterface), 0) > 0 ? { network_interface = [for x in rw.rule.source.networkInterface : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(rw.rule.source.siteNetworkSubnet), 0) > 0 ? { site_network_subnet = [for x in rw.rule.source.siteNetworkSubnet : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(rw.rule.source.floatingSubnet), 0) > 0 ? { floating_subnet = [for x in rw.rule.source.floatingSubnet : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(rw.rule.source.user), 0) > 0 ? { user = [for x in rw.rule.source.user : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(rw.rule.source.usersGroup), 0) > 0 ? { users_group = [for x in rw.rule.source.usersGroup : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(rw.rule.source.group), 0) > 0 ? { group = [for x in rw.rule.source.group : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(rw.rule.source.systemGroup), 0) > 0 ? { system_group = [for x in rw.rule.source.systemGroup : can(x.name) ? { name = x.name } : { id = x.id }] } : {}
    )
  }

  rule_bodies = {
    for name, rw in local.rules_by_name : name => merge(
      {
        name     = rw.rule.name
        enabled  = try(rw.rule.enabled, true)
        action   = try(rw.rule.action, "BYPASS")
        severity = try(rw.rule.severity, "MEDIUM")
      },
      try(rw.rule.description, "") != "" ? { description = rw.rule.description } : {},
      try(rw.rule.application, null) != null ? {
        application = can(rw.rule.application.name) ? { name = rw.rule.application.name } : { id = rw.rule.application.id }
      } : {},
      try(length(rw.rule.headers), 0) > 0 ? {
        headers = [for h in rw.rule.headers : { name = h.name, value = h.value }]
      } : {},
      try(rw.rule.schedule, null) != null ? {
        schedule = merge(
          { active_on = try(rw.rule.schedule.activeOn, "ALWAYS") },
          try(rw.rule.schedule.customTimeframe, null) != null ? {
            custom_timeframe = { from = rw.rule.schedule.customTimeframe.from, to = rw.rule.schedule.customTimeframe.to }
          } : {},
          try(rw.rule.schedule.customRecurring, null) != null ? {
            custom_recurring = { days = rw.rule.schedule.customRecurring.days, from = rw.rule.schedule.customRecurring.from, to = rw.rule.schedule.customRecurring.to }
          } : {}
        )
      } : {},
      length(local.atr_source_bodies[name]) > 0 ? { source = local.atr_source_bodies[name] } : {}
    )
  }
}

# Fails plan on 0 rules (e.g. truncated/wrong-tenant export) unless overridden.
resource "terraform_data" "guard_empty_policy" {
  lifecycle {
    precondition {
      condition     = var.allow_empty_policy || length(local.rules_data_raw) > 0
      error_message = "Policy JSON contains 0 rules. If intentional (greenfield/teardown), set allow_empty_policy = true. A truncated or wrong-tenant export would otherwise destroy the entire live policy."
    }
  }
}

resource "cato_app_tenant_restriction_section" "sections" {
  for_each = local.sections_data
  at = {
    position = "LAST_IN_POLICY"
  }
  section = {
    name = each.value.section_name
  }
}

resource "cato_app_tenant_restriction_rule" "rules" {
  depends_on = [cato_app_tenant_restriction_section.sections]
  for_each   = local.rules_by_name

  at = contains(keys(local.sections_data), each.value.rule.section.name) ? {
    position = "LAST_IN_SECTION"
    ref      = cato_app_tenant_restriction_section.sections[each.value.rule.section.name].id
    } : {
    position = "LAST_IN_POLICY"
  }

  rule = local.rule_bodies[each.key]
}

# Ordering + republish on changes.
resource "cato_bulk_atr_move_rule" "all_atr_rules" {
  depends_on = [cato_app_tenant_restriction_section.sections, cato_app_tenant_restriction_rule.rules]

  section_data = local.move_section_data
  rule_data    = local.move_rule_data
}
