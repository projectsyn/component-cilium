local ipcalc = import 'ipcalc.libsonnet';

local CiliumEgressGatewayPolicy(name) = {
  apiVersion: 'cilium.io/v2',
  kind: 'CiliumEgressGatewayPolicy',
  metadata+: {
    name: name,
    labels: {
      name: name,
    },
    annotations: {
      'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true,Prune=false',
    },
  },
};

local IsovalentEgressGatewayPolicy(name) = {
  apiVersion: 'isovalent.com/v1',
  kind: 'IsovalentEgressGatewayPolicy',
  metadata+: {
    name: name,
    labels: {
      name: name,
    },
    annotations: {
      'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true,Prune=false',
    },
  },
};

// Per-namespace egress IPs according to the selected design choice in
// https://kb.vshn.ch/oc4/explanations/decisions/cloudscale-cilium-egressip.html
// Requires that the shadow IPs are assigned to suitable dummy interfaces on
// the hosts matching the node selector and that SNAT rules are in place to
// map the shadow ranges to the public range.
local NamespaceEgressPolicy =
  function(
    interface_prefix,
    egress_range,
    shadow_ranges,
    node_selector,
    egress_ip,
    namespace,
    policy_resource_fn,
  )
    // Helper which computes the interface index of the egress IP.
    // Assumes that the IPs in egress_range are assigned to dummy interfaces
    // named
    //
    //   "<interface_prefix>_<i>"
    //
    // where i = 0..length(egress_range) - 1.
    local ifindex =
      local range = ipcalc.parse_ip_range(interface_prefix, egress_range);
      local start = ipcalc.ipval(range.start);
      local end = ipcalc.ipval(range.end);
      local ip = ipcalc.ipval(egress_ip);
      if start > end then
        error 'Egress IP range for "%s" is empty: %s > %s' % [
          interface_prefix,
          range.start,
          range.end,
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

    local compute_shadow_ip(shadow_range) =
      local range = ipcalc.parse_ip_range('shadow', shadow_range);
      local start = ipcalc.ipval(range.start);
      ipcalc.format_ipval(start + ifindex.value);

    local shadow_ips = [
      compute_shadow_ip(r)
      for r in shadow_ranges
    ];

    policy_resource_fn(namespace) {
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
          [if std.length(shadow_ips) > 0 then 'cilium.syn.tools/shadow-ips']:
            std.manifestJsonMinified(shadow_ips),
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

{
  CiliumEgressGatewayPolicy: CiliumEgressGatewayPolicy,
  IsovalentEgressGatewayPolicy: IsovalentEgressGatewayPolicy,
  NamespaceEgressPolicy: NamespaceEgressPolicy,
}
