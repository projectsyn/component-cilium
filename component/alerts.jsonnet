local kap = import 'lib/kapitan.libjsonnet';
local prom = import 'lib/prom.libsonnet';
local util = import 'util.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local clustermesh_enabled =
  std.get(params.cilium_helm_values, 'clustermesh', { config: { enabled: false } }).config.enabled;

local alertpatching = if util.isOpenshift then
  import 'lib/alert-patching.libsonnet'
else
  {
    filterPatchRules(g, patchNames): g,
  };

local clustermesh_group = {
  name: 'cilium-clustermesh.rules',
  rules: [
    {
      local this = self,
      alert: 'CiliumClustermeshRemoteClusterNotReady',
      expr: 'cilium_clustermesh_remote_cluster_readiness_status == 0',
      'for': '10m',
      labels: {
        severity: 'critical',
      },
      annotations: {
        runbook_url:
          'https://hub.syn.tools/cilium/runbooks/CiliumClustermeshRemoteClusterNotReady.html',
        message: 'Remote cluster ${{ labels.target_cluster }} not reachable from ${{ labels.source_node_name }}',
        description: |||
          Remote cluster ${{ labels.target_cluster }} has been unreachable from
          ${{ labels.source_node_name }} on cluster ${{ labels.source_cluster }} for the
          last %s.
        ||| % this['for'],
      },
    },
  ],
};

local clustermesh_alerts = prom.PrometheusRule('cilium-clustermesh') {
  spec+: {
    groups: [
      alertpatching.filterPatchRules(clustermesh_group, patchNames=false),
    ],
  },
};

{
  [if clustermesh_enabled && std.length(clustermesh_group.rules) > 0 then
    '10_clustermesh_alerts']: clustermesh_alerts,
}
