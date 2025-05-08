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
  if std.length(filtered) == 1 then {
    range: filtered[0],
    errmsg: '',
  } else {
    range: null,
    errmsg: if std.length(filtered) == 0 then
      local eranges = std.join(', ', [ r.egress_range for r in ranges ]);
      'No egress range found for %s, available ranges: %s'
      % [ egress_ip, eranges ]
    else
      local eranges = std.join(
        ', ', [ '%s (%s)' % [ r.if_prefix, r.egress_range ] for r in filtered ]
      );
      'Found multiple egress ranges which contain %s: %s. ' % [ egress_ip, eranges ] +
      "Please contact your cluster's administrator to resolve this range overlap",
  };

local setAnnotations(obj, annotations) = {
  apiVersion: obj.apiVersion,
  kind: obj.kind,
  metadata: {
    name: obj.metadata.name,
    annotations: annotations,
  },
};

local managed_policies_namespaces = [
  p.metadata.name
  for p in esp.context().egress_policies
];

local reconcileNamespace(namespace) =
  assert
    namespace != null && namespace.kind == 'Namespace'
    : 'reconcileNamespace() expects to be called with a Namespace resource';
  local ns_meta = namespace.metadata;
  local egress_ip = std.get(
    std.get(ns_meta, 'annotations', {}),
    'cilium.syn.tools/egress-ip'
  );
  if egress_ip != null then (
    local res = find_egress_range(config.egress_ranges, egress_ip);
    if res.range != null then
      local range = res.range;
      [
        egw.NamespaceEgressPolicy(
          range.if_prefix,
          range.egress_range,
          std.objectValues(range.shadow_ranges),
          range.node_selector,
          egress_ip,
          ns_meta.name,
          egw.IsovalentEgressGatewayPolicy
        ) {
          metadata+: {
            labels+: egw.espejoteLabel,
            ownerReferences: [ {
              controller: true,
              apiVersion: namespace.apiVersion,
              kind: namespace.kind,
              name: ns_meta.name,
              uid: ns_meta.uid,
            } ],
          },
        },
        setAnnotations(namespace, {
          'cilium.syn.tools/egress-ip-status': 'Egress IP assigned successfully',
        }),
      ]
    else
      [
        setAnnotations(namespace, {
          'cilium.syn.tools/egress-ip-status': res.errmsg,
        }),
      ]
  ) else if std.member(managed_policies_namespaces, ns_meta.name) then [
    esp.markForDelete(
      egw.IsovalentEgressGatewayPolicy(ns_meta.name)
    ),
    setAnnotations(namespace, {
      'cilium.syn.tools/egress-ip-status': 'Egress IP removed successfully',
    }),
  ];

if esp.triggerName() == 'namespace' then (
  local nsTrigger = esp.triggerData();
  if nsTrigger != null then reconcileNamespace(nsTrigger.resource)
) else
  local namespaces = esp.context().namespaces;
  std.flattenArrays(std.prune([
    reconcileNamespace(ns)
    for ns in namespaces
  ]))
