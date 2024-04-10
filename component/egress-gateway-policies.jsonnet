local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local CiliumEgressGatewayPolicy(name) =
  kube._Object('cilium.io/v2', 'CiliumEgressGatewayPolicy', name) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true',
      },
    },
  };


local policies = com.generateResources(
  params.egress_gateway.policies,
  CiliumEgressGatewayPolicy
);

// Per-namespace egress IPs according to the selected design choice in
// https://kb.vshn.ch/oc4/explanations/decisions/cloudscale-cilium-egressip.html
// Requires that the shadow IPs are assigned to suitable dummy interfaces on
// the hosts matching the node selector and that SNAT rules are in place to
// map the shadow ranges to the public range.
local NamespaceEgressPolicy =
  function(interface_prefix, egress_range, node_selector, egress_ip, namespace)
    // Convert an IPv4 address in A.B.C.D format to decimal format according
    // to the formula `A*256^3 + B*256^2 + C*256 + D`. The decimal format
    // allows us to make range comparisons and compute offsets into a range.
    local ipval(ip) = std.foldl(
      function(v, p) v * 256 + p,
      std.map(std.parseInt, std.split(ip, '.')),
      0
    );
    // Helper which computes the interface index of the egress IP.
    // Assumes that the IPs in egress_range are assigned to dummy interfaces
    // named
    //
    //   "<interface_prefix>_<i>"
    //
    // where i = 0..length(egress_range) - 1.
    local ifindex =
      // Extract start and end from the provided range, stripping any
      // whitespace.
      local range_parts = std.map(
        function(s) std.stripChars(s, ' '),
        std.split(egress_range, '-')
      );
      if std.length(range_parts) != 2 then
        error 'Expected IP range for "%s" in format "192.0.2.32-192.0.2.63",  got %s' % [
          interface_prefix,
          egress_range,
        ]
      else
        local start = ipval(range_parts[0]);
        local end = ipval(range_parts[1]);
        local ip = ipval(egress_ip);
        if start >= end then
          error 'Egress IP range for "%s" is empty: %s >= %s' % [
            interface_prefix,
            range_parts[0],
            range_parts[1],
          ]
        else if start > ip || end < ip then
          error 'Egress IP for namespace "%s" (%s) outside of configured IP range (%s) for egress range "%s"' % [
            namespace,
            egress_ip,
            egress_range,
            interface_prefix,
          ]
        else
          local idx = ip - start;
          local name = '%s_%d' % [ interface_prefix, idx ];
          if std.length(name) > 15 then
            error 'Interface name is longer than 15 characters: %s' % [ name ]
          else
            {
              value: idx,
              ifname: '%s_%d' % [ interface_prefix, idx ],
              debug: 'start=%d, end=%d, ip=%d' % [ start, end, ip ],
            };

    CiliumEgressGatewayPolicy(namespace) {
      metadata+: {
        annotations+: {
          'cilium.syn.tools/description':
            'Generated policy to assign egress IP %s in egress range "%s" (%s) to namespace %s.' % [
              egress_ip,
              interface_prefix,
              egress_range,
              namespace,
            ],
          'cilium.syn.tools/egress-ip': egress_ip,
          'cilium.syn.tools/interface-prefix': interface_prefix,
          'cilium.syn.tools/egress-range': egress_range,
          'cilium.syn.tools/source-namespace': namespace,
          'cilium.syn.tools/debug-interface-index': ifindex.debug,
        },
      },
      spec: {
        destinationCIDRs: [ '0.0.0.0/0' ],
        egressGroups: [
          {
            nodeSelector: {
              matchLabels: node_selector,
            },
            interface: ifindex.ifname,
          },
        ],
        selectors: [
          {
            podSelector: {
              matchLabels: {
                'io.kubernetes.pod.namespace': namespace,
              },
            },
          },
        ],
      },
    };

local egress_ip_policies = std.flattenArrays([
  local cfg = params.egress_gateway.egress_ip_ranges[interface_prefix];
  [
    NamespaceEgressPolicy(
      interface_prefix,
      cfg.egress_range,
      cfg.node_selector,
      cfg.namespace_egress_ips[namespace],
      namespace
    )
    for namespace in std.objectFields(cfg.namespace_egress_ips)
    if cfg.namespace_egress_ips[namespace] != null
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

{
  [if params.egress_gateway.enabled && std.length(params.egress_gateway.policies) > 0 then
    '20_egress_gateway_policies']: policies,
  [if params.egress_gateway.enabled && std.length(egress_ip_policies) > 0 then
    '20_namespace_egress_ip_policies']: validate(egress_ip_policies),
}
