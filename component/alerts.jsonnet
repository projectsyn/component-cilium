local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local prom = import 'lib/prom.libsonnet';
local util = import 'util.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local ignoreNames = com.renderArray(params.alerts.ignoreNames);

local clustermesh_enabled =
  std.get(params.cilium_helm_values, 'clustermesh', { config: { enabled: false } }).config.enabled;

local alertpatching = if util.isOpenshift then
  import 'lib/alert-patching.libsonnet'
else
  {
    filterPatchRules(g, ignoreNames, patches, preserveRecordingRules, patchNames): g,
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
        message: 'Remote cluster {{ $labels.target_cluster }} not reachable from {{ $labels.source_node_name }}',
        description: |||
          Remote cluster {{ $labels.target_cluster }} has been unreachable from
          {{ $labels.source_node_name }} on cluster {{ $labels.source_cluster }} for the
          last %s.
        ||| % this['for'],
      },
    },
  ],
};

local clustermesh_alerts = prom.PrometheusRule('cilium-clustermesh') {
  spec+: {
    groups: [
      alertpatching.filterPatchRules(
        clustermesh_group,
        ignoreNames=ignoreNames,
        patches=params.alerts.patches,
        preserveRecordingRules=true,
        patchNames=false,
      ),
    ],
  },
};

local ebpf_group = {
  name: 'cilium-ebpf.rules',
  rules: [
    {
      local this = self,
      alert: 'CiliumBpfMapUtilizationHigh',
      expr: 'cilium_bpf_map_pressure > 0.5',
      'for': '10m',
      labels: {
        severity: 'warning',
      },
      annotations: {
        runbook_url:
          'https://hub.syn.tools/cilium/runbooks/CiliumBpfMapPressureHigh.html',
        message: 'High BPF map utilization on {{ $labels.node }}',
        description: |||
          BPF map utilization for map {{ $labels.map_name }} has been above
          50%% on node {{ $labels.node }} for the last %s.
        ||| % this['for'],
      },
    },
    {
      local this = self,
      alert: 'CiliumBpfMapUtilizationExtremelyHigh',
      expr: 'cilium_bpf_map_pressure > 0.9',
      'for': '10m',
      labels: {
        severity: 'critical',
      },
      annotations: {
        runbook_url:
          'https://hub.syn.tools/cilium/runbooks/CiliumBpfMapPressureExtremelyHigh.html',
        message: 'Extremely High BPF map utilization on {{ $labels.node }}',
        description: |||
          BPF map utilization for map {{ $labels.map_name }} has been above
          90%% on node {{ $labels.node }} for the last %s.
        ||| % this['for'],
      },
    },
    {
      local this = self,
      alert: 'CiliumBpfOperationErrorRateHigh',
      expr: '(rate(cilium_bpf_map_ops_total{outcome="fail"}[1m]) / rate(cilium_bpf_map_ops_total{}[1m])) > 0.5',
      'for': '10m',
      labels: {
        severity: 'critical',
      },
      annotations: {
        runbook_url:
          'https://hub.syn.tools/cilium/runbooks/CiliumBpfOperationErrorRateHigh.html',
        message: 'High BPF error rate on {{ $labels.node }}',
        description: |||
          BPF error rate for map {{ $labels.map_name }} has been above
          50%% on node {{ $labels.node }} for the last %s.
        ||| % this['for'],
      },
    },
  ],
};

local ebpf_alerts = prom.PrometheusRule('cilium-ebpf') {
  spec+: {
    groups: [
      alertpatching.filterPatchRules(
        ebpf_group,
        ignoreNames=ignoreNames,
        patches=params.alerts.patches,
        preserveRecordingRules=true,
        patchNames=false,
      ),
    ],
  },
};

local additional_group =
  local parseRuleName(rname) =
    local rparts = std.splitLimit(rname, ':', 1);
    assert
      std.length(rparts) == 2 :
      'Expected custom alert rule to be prefixed with `record:` or `alert:`.';
    assert
      std.member([ 'alert', 'record' ], rparts[0]) :
      'Expected custom alert rule to be prefixed with `record:` or `alert:`, got `%s:`.' % rparts[0];
    { [rparts[0]]: rparts[1] };
  {
    name: 'cilium-user.rules',
    rules: [
      params.alerts.additionalRules[rname] + parseRuleName(rname)
      for rname in std.objectFields(params.alerts.additionalRules)
    ],
  };

local additional_alerts = prom.PrometheusRule('cilium-custom') {
  spec+: {
    groups: [
      alertpatching.filterPatchRules(
        additional_group,
        ignoreNames=ignoreNames,
        patches=params.alerts.patches,
        preserveRecordingRules=true,
        patchNames=false,
      ),
    ],
  },
};

{
  [if clustermesh_enabled && std.length(clustermesh_group.rules) > 0 then
    '10_clustermesh_alerts']: clustermesh_alerts,
  [if std.length(ebpf_alerts.spec.groups[0].rules) > 0 then
    '10_ebpf_alerts']: ebpf_alerts,
  [if std.length(additional_group.rules) > 0 then
    '10_custom_alerts']: additional_alerts,
}
