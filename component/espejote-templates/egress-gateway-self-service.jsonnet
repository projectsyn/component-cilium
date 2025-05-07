local esp = import 'espejote.libsonnet';

local config = import 'egress-gateway/config.json';
local egw = import 'egress-gateway/egress-gateway.libsonnet';
local ipcalc = import 'egress-gateway/ipcalc.libsonnet';

// find_egress_range expects a list of egress range objects which contain the
// interface prefix in a field. This list is precomputed by the Commodore
// component and provided as `"config.json".egress_ranges`.
local find_egress_range(ranges, egress_ip) =
  local eip = ipcalc.ipval(egress_ip);
  local check_fn(rspec) =
    local range = ipcalc.parse_ip_range(rspec.if_prefix, rspec.egress_range);
    local start = ipcalc.ipval(range.start);
    local end = ipcalc.ipval(range.end);
    eip >= start && eip <= end;
  local filtered = std.filter(check_fn, ranges);
  // TODO(sg): do we have better facilities to emit errors in Espejote?
  assert
    std.length(filtered) == 1
    : 'Expected 1 egress ip range containing %s, got %d'
      % [ egress_ip, std.length(filtered) ];
  filtered[0];

if esp.triggerName() == 'namespace' then
  local namespace = esp.triggerData();
  assert namespace != null : 'Expected namespace trigger to have trigger data';
  local ns_meta = namespace.resource.metadata;
  local egress_ip = std.get(
    std.get(ns_meta, 'annotations', {}),
    'cilium.syn.tools/egress-ip'
  );
  if egress_ip != null then
    local range = find_egress_range(config.egress_ranges, egress_ip);
    egw.NamespaceEgressPolicy(
      range.if_prefix,
      range.egress_range,
      std.objectValues(range.shadow_ranges),
      range.node_selector,
      egress_ip,
      ns_meta.name,
      egw.IsovalentEgressGatewayPolicy
    )
