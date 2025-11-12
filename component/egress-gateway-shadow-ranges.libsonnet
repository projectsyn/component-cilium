local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local egw = import 'espejote-templates/egress-gateway.libsonnet';
local ipcalc = import 'espejote-templates/ipcalc.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

// NOTE(sg): This expects that each shadow range fully fits into a /24.
local egress_ip_shadow_ranges =
  // Helper to extract the /24 prefix of the IP range passed as `range`. The
  // function raises an error if the provided range spans multiple /24.
  local extract_prefix(prefix, hostname, range) =
    // find <start_prefix>.0
    local start0 = ipcalc.ipval(std.mapWithIndex(
      function(idx, elem)
        if idx < 3 then elem else '0',
      std.split(range.start, '.'),
    ));
    // find <end_prefix>.255
    local end255 = ipcalc.ipval(std.mapWithIndex(
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
    local public_range = egw.read_egress_range(egress_range.prefix, egress_range.config);
    local public_len = ipcalc.ipval(public_range.end) - ipcalc.ipval(public_range.start);
    local shadow_len = ipcalc.ipval(range.end) - ipcalc.ipval(range.start);

    if public_len != shadow_len then
      error "Shadow IP range %s-%s for '%s' in '%s' doesn't match length of egress IP range %s" % [
        range.start,
        range.end,
        hostname,
        egress_range.prefix,
        public_range,
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
            ipcalc.parse_ip_range(
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
                image: '%(registry)s/%(repository)s:%(tag)s' % params.images.oc,
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

{
  manifests: egress_ip_shadow_ranges,
}
