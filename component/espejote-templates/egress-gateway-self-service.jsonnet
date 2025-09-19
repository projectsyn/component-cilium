local esp = import 'espejote.libsonnet';

local config = import 'egress-gateway/config.json';
local egw = import 'egress-gateway/egress-gateway.libsonnet';
local ipcalc = import 'egress-gateway/ipcalc.libsonnet';

// setAnnotations is a helper that generates a minimal partial manifest to
// set/update annotations with server-side apply.
local setAnnotations(obj, annotations) = {
  apiVersion: obj.apiVersion,
  kind: obj.kind,
  metadata: {
    name: obj.metadata.name,
    annotations: annotations,
  },
};

// Collect list of namespaces for which we currently manage egress policies
// based on the `egress_policies` context (which only contains
// `IsovalentEgressGatewayPolicy` resources which have the `egw.espejoteLabel`
// set).
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
    local res = egw.find_egress_range(config.egress_ranges, egress_ip);
    if res.range != null then
      // when we have a range, generate a IsovalentEgressGatewayPolicy (with
      // ownerReference pointing to the namespace, and labeled as managed by
      // us) and update the namespace with an informational message.
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
      // when we didn't find a unique egress range for the requested IP, add
      // the error message to the namespace.
      [
        setAnnotations(namespace, {
          'cilium.syn.tools/egress-ip-status': res.errmsg,
        }),
      ]
  ) else if std.member(managed_policies_namespaces, ns_meta.name) then [
    // when the namespace doesn't have an egress-ip annotation, but we have a
    // managed IsovalentEgressGatewayPolicy, delete it.
    esp.markForDelete(
      egw.IsovalentEgressGatewayPolicy(ns_meta.name)
    ),
    setAnnotations(namespace, {
      'cilium.syn.tools/egress-ip-status': 'Egress IP removed successfully',
    }),
  ];

// check if the object is getting deleted by checking if it has
// `metadata.deletionTimestamp`.
local inDelete(obj) = std.get(obj.metadata, 'deletionTimestamp', '') != '';

if esp.triggerName() == 'namespace' then (
  // Handle single namespace update on namespace trigger
  local nsTrigger = esp.triggerData();
  // nsTrigger can be null if we're called when the namespace is getting
  // deleted. If it's not null, we still don't want to do anything when the
  // namespace is getting deleted.
  if nsTrigger != null && std.get(nsTrigger, 'resource') != null && !inDelete(nsTrigger.resource) then
    reconcileNamespace(nsTrigger.resource)
) else
  // Reconcile all namespaces for jsonnetlibrary update or managedresource
  // reconcile.
  local namespaces = esp.context().namespaces;
  std.flattenArrays(std.prune([
    reconcileNamespace(ns)
    for ns in namespaces
    if !inDelete(ns)
  ]))
