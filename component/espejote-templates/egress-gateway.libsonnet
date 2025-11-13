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
    destination_cidrs=null,
    bgp_policy_labels={},
    policy_labels={},
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

    local dest_cidrs = if destination_cidrs == null || std.length(destination_cidrs) == 0 then
      [ '0.0.0.0/0' ]
    else
      assert
        std.isArray(destination_cidrs)
        : 'Expected `destination_cidrs` to be an array, got %s' % std.type(destination_cidrs);
      destination_cidrs;

    local bgp_egress_ip = std.length(bgp_policy_labels) > 0;

    policy_resource_fn(namespace) {
      metadata+: {
        annotations+: {
          'cilium.syn.tools/description':
            'Generated policy to assign %segress IP %s in egress range "%s" (%s) to namespace %s.' % [
              if bgp_egress_ip then 'BGP ' else '',
              egress_ip,
              interface_prefix,
              egress_range,
              namespace,
            ],
          [if bgp_egress_ip then 'cilium.syn.tools/experimental-policy']: 'true',
          'cilium.syn.tools/egress-ip': egress_ip,
          'cilium.syn.tools/interface-prefix': interface_prefix,
          'cilium.syn.tools/egress-range': egress_range,
          'cilium.syn.tools/source-namespace': namespace,
          [if !bgp_egress_ip then 'cilium.syn.tools/debug-interface-index']: ifindex.debug,
          [if std.length(shadow_ips) > 0 then 'cilium.syn.tools/shadow-ips']:
            std.manifestJsonMinified(shadow_ips),
        },
        labels+: policy_labels + bgp_policy_labels,
      },
      spec: {
        destinationCIDRs: dest_cidrs,
        [if bgp_egress_ip then 'egressCIDRs']: [ '%s/32' % egress_ip ],
        egressGroups: [
          {
            nodeSelector: {
              matchLabels: node_selector,
            },
          } + if bgp_egress_ip then {
            maxGatewayNodes: 1,
          } else {
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

local EgressInterfaceNNCPs(NNCP, ep, interface_prefix, egress_range, shadow_ranges) = [
  local shadow_ip =
    local ifindex =
      local debuginfo = std.foldl(
        function(i, e)
          local parts = std.splitLimit(e, '=', 1);
          i { [parts[0]]: std.parseInt(parts[1]) },
        std.split(
          ep.metadata.annotations['cilium.syn.tools/debug-interface-index'],
          ', '
        ),
        {}
      );
      debuginfo.ip - debuginfo.start;
    local sr = ipcalc.parse_ip_range('shadow range for "%s" in "%s"' % [
      node,
      interface_prefix,
    ], shadow_ranges[node]);
    ipcalc.format_ipval(ipcalc.ipval(sr.start) + ifindex);
  NNCP('egress-interface-%s-%s' % [
    ep.metadata.name,
    node,
  ]) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-wave': '-10',
        'cilium.syn.tools/description':
          'Generated policy to configure egress interface "%s" for shadow range "%s" associated with egress range "%s" (%s) on node "%s".' % [
            ep.spec.egressGroups[0].interface,
            shadow_ranges[node],
            interface_prefix,
            '%(start)s - %(end)s' % egress_range,
            node,
          ],
      },
      labels+: {
        'cilium.syn.tools/egress-policy': ep.metadata.name,
      },
    },
    spec: {
      nodeSelector: {
        'kubernetes.io/hostname': node,
      },
      desiredState: {
        interfaces: [
          {
            name: '%s' % ep.spec.egressGroups[0].interface,
            type: 'dummy',
            ipv4: {
              address: [ {
                ip: shadow_ip,
                'prefix-length': 32,
              } ],
              dhcp: false,
              enabled: true,
            },
          },
        ],
      },
    },
  }
  for node in std.objectFields(shadow_ranges)
];

local espejoteLabel = {
  'cilium.syn.tools/managed-by': 'espejote_cilium_namespace-egress-ips',
};

// read_egress_range extracts the egress range from the passed config object,
// either from field `egress_range` or from field `egress_cidr`.
// When reading from field `egress_cidr` the function also respects fields
// `skip_first` and `skip_last` when generating the resulting range object.
local read_egress_range(prefix, config) =
  local ekey = std.setDiff(
    std.set([ 'egress_range', 'egress_cidr' ]),
    std.set(std.objectFields(config))
  );
  if std.length(ekey) != 1 then
    error
      'egress_ip_ranges` entries are expected to have exactly one of ' +
      '`egress_range` and `egress_cidr`. entry "%s" has %s.' % [
        prefix,
        if std.length(ekey) == 2 then 'neither'
        else if std.length(ekey) == 0 then 'both'
        else 'a weird configuration',
      ]
  else
    if std.objectHas(config, 'egress_range') then
      local erange = ipcalc.parse_ip_range(prefix, config.egress_range);
      erange
    else
      local ecidr = ipcalc.parse_cidr(prefix, config.egress_cidr);
      {
        start: if std.get(config, 'skip_first', false) then
          ecidr.host_min
        else
          ecidr.network_address,
        end: if std.get(config, 'skip_last', false) then
          ecidr.host_max
        else
          ecidr.broadcast_address,
      };


// find_egress_range expects a list of egress range objects which contain the
// interface prefix in a field. This list is precomputed by the Commodore
// component and provided to the Espejote template as
// `"config.json".egress_ranges`.
// This function returns an object with field `range` containing the range of
// the IP if unique or `null` if not unique or not found, and field `errmsg`
// containing an error message if `range` is null.
local find_egress_range(ranges, egress_ip) =
  local eip = ipcalc.ipval(egress_ip);
  local check_fn(rspec) =
    local range = read_egress_range(rspec.if_prefix, rspec);
    local start = ipcalc.ipval(range.start);
    local end = ipcalc.ipval(range.end);
    eip >= start && eip <= end;
  local filtered = std.filter(check_fn, ranges);
  if std.length(filtered) == 1 then {
    range: filtered[0],
    errmsg: '',
  } else {
    local read_erange_str(r) =
      local er = read_egress_range(r.if_prefix, r);
      '%(start)s - %(end)s' % er,
    range: null,
    errmsg: if std.length(filtered) == 0 then
      local eranges = std.join(', ', [ read_erange_str(r) for r in ranges ]);
      'No egress range found for %s, available ranges: %s'
      % [ egress_ip, eranges ]
    else
      local eranges = std.join(
        ', ', [ '%s (%s)' % [ r.if_prefix, read_erange_str(r) ] for r in filtered ]
      );
      'Found multiple egress ranges which contain %s: %s. ' % [ egress_ip, eranges ] +
      "Please contact your cluster's administrator to resolve this range overlap",
  };

{
  CiliumEgressGatewayPolicy: CiliumEgressGatewayPolicy,
  IsovalentEgressGatewayPolicy: IsovalentEgressGatewayPolicy,
  NamespaceEgressPolicy: NamespaceEgressPolicy,
  EgressInterfaceNNCPs: EgressInterfaceNNCPs,
  espejoteLabel: espejoteLabel,
  find_egress_range: find_egress_range,
  read_egress_range: read_egress_range,
}
