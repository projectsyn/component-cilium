local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local egw = import 'espejote-templates/egress-gateway.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local EgressGatewayPolicy(name) =
  if params.release == 'enterprise' then
    egw.IsovalentEgressGatewayPolicy(name)
  else
    egw.CiliumEgressGatewayPolicy(name);

local policies = com.generateResources(
  params.egress_gateway.policies,
  EgressGatewayPolicy
);

local egress_ip_policies = std.flattenArrays([
  local cfg = params.egress_gateway.egress_ip_ranges[interface_prefix];
  local ns_egress_ips = std.get(cfg, 'namespace_egress_ips', {});
  [
    egw.NamespaceEgressPolicy(
      interface_prefix,
      cfg.egress_range,
      std.objectValues(std.get(cfg, 'shadow_ranges', {})),
      cfg.node_selector,
      ns_egress_ips[namespace],
      namespace,
      EgressGatewayPolicy,
    )
    for namespace in std.objectFields(ns_egress_ips)
    if ns_egress_ips[namespace] != null
  ]
  for interface_prefix in std.objectFields(params.egress_gateway.egress_ip_ranges)
  if params.egress_gateway.egress_ip_ranges[interface_prefix] != null
]);

// Check for duplicated source namespaces in the provided list of policies
// Internal accumulator is an object which uses the source namespace as key
// and contains the full policies as values. The function returns the values
// of this object.
local validate(policies) = std.objectValues(std.foldl(
  function(seen, p)
    local ns =
      p.spec.selectors[0].podSelector.matchLabels['io.kubernetes.pod.namespace'];
    if std.objectHas(seen, ns) then
      error 'duplicated source namespace "%s" for policies in egress ranges "%s" and "%s"' % [
        ns,
        seen[ns].metadata.annotations['cilium.syn.tools/interface-prefix'],
        p.metadata.annotations['cilium.syn.tools/interface-prefix'],
      ]
    else
      seen {
        [ns]: p,
      },
  policies,
  {}
));

local shadow_ranges = import 'egress-gateway-shadow-ranges.libsonnet';
local self_service = import 'egress-gateway-self-service.libsonnet';

{
  [if params.egress_gateway.enabled && std.length(params.egress_gateway.policies) > 0 then
    '20_egress_gateway_policies']: policies,
  [if params.egress_gateway.enabled && std.length(egress_ip_policies) > 0 then
    '20_namespace_egress_ip_policies']: validate(egress_ip_policies),
  [if params.egress_gateway.enabled &&
      params.egress_gateway.generate_shadow_ranges_configmap &&
      std.length(shadow_ranges.manifests) > 0 then
    '30_egress_ip_shadow_ranges']: shadow_ranges.manifests,
  [if params.egress_gateway.enabled &&
      params.egress_gateway.self_service_namespace_ips then
    '40_egress_ip_managed_resource']: self_service.manifests,
}
