local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.cilium;

local replaceDeprecatedIPv4PodCIDR = {
  ipam+: {
    operator+:
      if
        'operator' in super &&
        std.objectHas(super.operator, 'clusterPoolIPv4PodCIDR') &&
        super.operator.clusterPoolIPv4PodCIDR != null
      then
        std.trace(
          "Helm value 'clusterPoolIPv4PodCIDR' is deprecated. " +
          "Users should switch to 'clusterPoolIPv4PodCIDRList'",
          {
            clusterPoolIPv4PodCIDR:: null,
            clusterPoolIPv4PodCIDRList: [ super.clusterPoolIPv4PodCIDR ],
          }
        )
      else {},
  },
};

local renderPodCIDRList = {
  ipam+: {
    operator+:
      if
        'operator' in super &&
        std.objectHas(super.operator, 'clusterPoolIPv4PodCIDRList')
      then
        {
          clusterPoolIPv4PodCIDRList:
            com.renderArray(super.clusterPoolIPv4PodCIDRList),
        }
      else {},
  },
};

local cilium_values = std.prune(
  params.cilium_helm_values +
  replaceDeprecatedIPv4PodCIDR +
  renderPodCIDRList
);

local helm_values = {
  opensource: cilium_values,
  enterprise: {
    cilium: {
      enterprise: {
        egressGatewayHA: {
          // Enable HA egress gateway on Cilium EE by default when the regular
          // egress gateway is enabled.
          // we do this before the user-provided values, so users can still
          // enable the HA egress gateway without enabling the regular egress
          // gateway.
          enabled: cilium_values.egressGateway.enabled,
        },
      },
    } + com.makeMergeable(cilium_values),
    'hubble-enterprise': std.prune(params.hubble_enterprise_helm_values),
    'hubble-ui': std.prune(params.hubble_ui_helm_values),
  },
};

local legacy_values =
  if std.objectHas(params, 'helm_values') then
    std.trace(
      'Parameter `helm_values` is deprecated. ' +
      'Please move your configs to `cilium_helm_values`, ' +
      '`hubble_enterprise_helm_values` or `hubble_ui_helm_values`.',
      com.makeMergeable(params.helm_values)
    )
  else
    {};

{
  cilium_values: cilium_values,
  values:
    if !std.member([ 'opensource', 'enterprise' ], params.release) then
      error 'Unknown release type "%s". Supported values are "opensource" and "enterprise".' % params.release
    else
      helm_values[params.release] + legacy_values,
}
