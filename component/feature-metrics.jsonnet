local kap = import 'lib/kapitan.libjsonnet';
local util = import 'util.libsonnet';

local inv = kap.inventory();

local prom = if util.isOpenshift then
  import 'lib/prom.libsonnet'
else
  assert
    std.member(inv.applications, 'prometheus')
    : 'Cilium Enterprise feature metrics rendering requires component-prometheus!';
  import 'lib/prometheus.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local clustermesh_enabled =
  std.get(params.cilium_helm_values.clustermesh, 'config', { enabled: false }).enabled;
local egress_gateway_enabled = params.egress_gateway.enabled;
local transparent_encryption_enabled =
  std.get(params.cilium_helm_values, 'encryption', { enabled: false }).enabled;


local feature_flags = [
  { key: 'clustermesh', enabled: clustermesh_enabled },
  { key: 'egress-gateway', enabled: egress_gateway_enabled },
  { key: 'transparent-encryption', enabled: transparent_encryption_enabled },
];

local feature_group = {
  name: 'cilium-feature-metrics.rules',
  rules: [
    {
      record: 'cilium_features',
      labels: {
        feature: f.key,
      },
      expr: if f.enabled then 'vector(1)' else 'vector(0)',
    }
    for f in feature_flags
  ],
};

local feature_record = prom.PrometheusRule('cilium-features') {
  spec+: {
    groups: [ feature_group ],
  },
};

if params.release == 'enterprise' then
  {
    [if std.length(feature_group.rules) > 0 then '10_cilium_features_metrics']: feature_record,
  }
else
  std.trace('Compiling component with Cilium OSS: not rendering enterprise feature metrics', {})
