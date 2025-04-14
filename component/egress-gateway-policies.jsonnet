local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local CiliumEgressGatewayPolicy(name) =
  kube._Object('cilium.io/v2', 'CiliumEgressGatewayPolicy', name) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true,Prune=false',
      },
    },
  };

local IsovalentEgressGatewayPolicy(name) =
  kube._Object('isovalent.com/v1', 'IsovalentEgressGatewayPolicy', name) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true',
      },
    },
  };

local EgressGatewayPolicy(name) =
  if params.release == 'enterprise' then
    IsovalentEgressGatewayPolicy(name)
  else
    CiliumEgressGatewayPolicy(name);

local policies = com.generateResources(
  params.egress_gateway.policies,
  EgressGatewayPolicy
);

// Convert an IPv4 address in A.B.C.D format that's already been split into an
// array to decimal format according to the formula `A*256^3 + B*256^2 + C*256
// + D`. The decimal format allows us to make range comparisons and compute
// offsets into a range.
// Parameter ip can either be the IP as a string, or already split into an
// array holding each dotted part.
local ipval(ip) =
  local iparr =
    if std.type(ip) == 'array' then
      ip
    else
      std.split(ip, '.');
  std.foldl(
    function(v, p) v * 256 + p,
    std.map(std.parseInt, iparr),
    0
  );

// Extract start and end from the provided range, stripping any
// whitespace. `prefix` is only used for the error message.
local parse_ip_range(prefix, rangespec) =
  local range_parts = std.map(
    function(s) std.stripChars(s, ' '),
    std.split(rangespec, '-')
  );
  if std.length(range_parts) != 2 then
    error 'Expected IP range for "%s" in format "192.0.2.32-192.0.2.63",  got %s' % [
      prefix,
      rangespec,
    ]
  else
    {
      start: range_parts[0],
      end: range_parts[1],
    };


// Per-namespace egress IPs according to the selected design choice in
// https://kb.vshn.ch/oc4/explanations/decisions/cloudscale-cilium-egressip.html
// Requires that the shadow IPs are assigned to suitable dummy interfaces on
// the hosts matching the node selector and that SNAT rules are in place to
// map the shadow ranges to the public range.
local NamespaceEgressPolicy =
  function(interface_prefix, egress_range, node_selector, egress_ip, namespace)
    // Helper which computes the interface index of the egress IP.
    // Assumes that the IPs in egress_range are assigned to dummy interfaces
    // named
    //
    //   "<interface_prefix>_<i>"
    //
    // where i = 0..length(egress_range) - 1.
    local ifindex =
      local range = parse_ip_range(interface_prefix, egress_range);
      local start = ipval(range.start);
      local end = ipval(range.end);
      local ip = ipval(egress_ip);
      if start >= end then
        error 'Egress IP range for "%s" is empty: %s >= %s' % [
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

    EgressGatewayPolicy(namespace) {
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

// NOTE(sg): This expects that each shadow range fully fits into a /24.
local egress_ip_shadow_ranges =
  // Helper to extract the /24 prefix of the IP range passed as `range`. The
  // function raises an error if the provided range spans multiple /24.
  local extract_prefix(prefix, hostname, range) =
    // find <start_prefix>.0
    local start0 = ipval(std.mapWithIndex(
      function(idx, elem)
        if idx < 3 then elem else '0',
      std.split(range.start, '.'),
    ));
    // find <end_prefix>.255
    local end255 = ipval(std.mapWithIndex(
      function(idx, elem)
        if idx < 3 then elem else '255',
      std.split(range.end, '.'),
    ));
    if end255 - start0 + 1 > 256 then
      error "Shadow range %s-%s for '%s' in '%s' spans multiple /24. This isn't currently supported." % [
        range.start,
        range.end,
        hostname,
        prefix,
      ]
    else
      // extract the /24 prefix from `range.start` now that we know that the
      // range fits into a single /24.
      std.join('.', std.split(range.start, '.')[0:3]);

  local check_length(hostname, egress_range, range) =
    local public_range = parse_ip_range(
      egress_range.prefix,
      egress_range.config.egress_range
    );
    local public_len = ipval(public_range.end) - ipval(public_range.start);
    local shadow_len = ipval(range.end) - ipval(range.start);

    if public_len != shadow_len then
      error "Shadow IP range %s-%s for '%s' in '%s' doesn't match length of egress IP range %s" % [
        range.start,
        range.end,
        hostname,
        egress_range.prefix,
        egress_range.config.egress_range,
      ]
    else
      range;


  // Transform egress_ip_ranges.<range>.shadow_ranges into the format expected
  // by the systemd service (and script) managed in component
  // openshift4-nodes.
  local config = std.foldl(
    // Collect egress interface IP ranges by node. This object can be used to
    // generate the configmap that openshift4-nodes expects.
    function(data, egress_range)
      data {
        [hostname]+: {
          local range = check_length(
            hostname,
            egress_range,
            parse_ip_range(
              egress_range.prefix,
              egress_range.config.shadow_ranges[hostname]
            )
          ),
          [egress_range.prefix]:
            {
              base: extract_prefix(egress_range.prefix, hostname, range),
              from: std.split(range.start, '.')[3],
              to: std.split(range.end, '.')[3],
            },
        }
        for hostname in std.objectFields(egress_range.config.shadow_ranges)
      },
    // transform egress_ip_ranges object into a list of key-value pair
    // objects, so we can more easily implement the transformation.
    [
      local data = params.egress_gateway.egress_ip_ranges[interface_prefix];
      {
        prefix: interface_prefix,
        config: data,
      }
      for interface_prefix in std.objectFields(params.egress_gateway.egress_ip_ranges)
      if params.egress_gateway.egress_ip_ranges[interface_prefix] != null
         && std.objectHas(params.egress_gateway.egress_ip_ranges[interface_prefix], 'shadow_ranges')
         && params.egress_gateway.egress_ip_ranges[interface_prefix].shadow_ranges != null
    ],
    {}
  );

  // generate 1 configmap for all egress ranges.
  local configmap =
    kube.ConfigMap('eip-shadow-ranges') {
      data: {
        [hostname]: std.manifestJsonMinified(config[hostname])
        for hostname in std.objectFields(config)
      },
    };

  // Generate 1 daemonset per unique node selector across all configured
  // egress ranges. The daemonset's purpose is to make the configmap available
  // to the kubelet on the node, so that we can use the Kubelet kubeconfig for
  // the script managed by openshift4-nodes.
  local daemonset_configs = std.foldl(
    function(dses, d) dses + d,
    [
      local sel = params.egress_gateway.egress_ip_ranges[interface_prefix].node_selector;
      local sel_hash = std.md5(std.manifestJsonMinified(sel));
      { [sel_hash]+: sel }
      for interface_prefix in std.objectFields(params.egress_gateway.egress_ip_ranges)
      if params.egress_gateway.egress_ip_ranges[interface_prefix] != null
    ],
    {}
  );

  local make_daemonset(ds_configs, sel_hash) =
    kube.DaemonSet(
      'eip-shadow-ranges-%s' % std.substr(
        sel_hash, std.length(sel_hash) - 5, 5
      )
    ) {
      metadata+: {
        annotations+: {
          'cilium.syn.tools/description':
            'Daemonset which ensures that the Kubelet on the nodes where the'
            + ' pods are scheduled can access configmap %s in namespace %s.' %
              [
                configmap.metadata.name,
                params._namespace,
              ],
        },
      },
      spec+: {
        template+: {
          spec+: {
            containers_: {
              sleep: kube.Container('sleep') {
                image: '%(registry)s/%(image)s:%(tag)s' % params.images.kubectl,
                command: [ '/bin/sh', '-c', 'trap : TERM INT; sleep infinity & wait' ],
                volumeMounts_: {
                  shadow_ranges: {
                    mountPath: '/data/eip-shadow-ranges',
                  },
                },
              },
            },
            nodeSelector: ds_configs[sel_hash],
            volumes_: {
              shadow_ranges: {
                configMap: {
                  name: configmap.metadata.name,
                },
              },
            },
          },
        },
      },
    };

  local daemonsets =
    if std.length(params.egress_gateway.shadow_ranges_daemonset_node_selector) == 0 then [
      make_daemonset(daemonset_configs, sel_hash)
      for sel_hash in std.objectFields(daemonset_configs)
    ] else
      local sel_hash =
        std.md5(std.manifestJsonMinified(
          params.egress_gateway.shadow_ranges_daemonset_node_selector
        ));
      [
        make_daemonset({
          [sel_hash]:
            params.egress_gateway.shadow_ranges_daemonset_node_selector,
        }, sel_hash),
      ];

  [ configmap ] + daemonsets;

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
  [if params.egress_gateway.enabled &&
      params.egress_gateway.generate_shadow_ranges_configmap &&
      std.length(egress_ip_shadow_ranges) > 0 then
    '30_egress_ip_shadow_ranges']: egress_ip_shadow_ranges,
}
