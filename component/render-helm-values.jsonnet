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

local cilium_values =
  params.cilium_helm_values +
  replaceDeprecatedIPv4PodCIDR +
  renderPodCIDRList;

local helm_values = {
  opensource: cilium_values,
  enterprise: {
    cilium: cilium_values,
    'hubble-enterprise': {
      enabled: false,
      enterprise: {
        enabled: false,
      },
    },
    'hubble-ui': {
      enabled: false,
    },
  },
};

{
  cilium_values: cilium_values,
  values:
    if !std.member([ 'opensource', 'enterprise' ], params.release) then
      error 'Unknown release type "%s". Supported values are "opensource" and "enterprise".' % params.release
    else
      helm_values[params.release] + com.makeMergeable(params.helm_values),
}
