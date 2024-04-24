local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.cilium;

local cilium_values =
  local ipam = std.get(
    params.cilium_helm_values, 'ipam', { operator: {} }
  );
  local ipamoperator = std.get(
    ipam, 'operator', {}
  );
  params.cilium_helm_values +
  if
    std.objectHas(ipamoperator, 'clusterPoolIPv4PodCIDR') &&
    ipamoperator.clusterPoolIPv4PodCIDR != null
  then
    std.trace(
      "Helm value 'clusterPoolIPv4PodCIDR' is deprecated. " +
      "Users should switch to 'clusterPoolIPv4PodCIDRList'",
      {
        ipam+: {
          operator+: {
            clusterPoolIPv4PodCIDR:: null,
            clusterPoolIPv4PodCIDRList: [ super.clusterPoolIPv4PodCIDR ],
          },
        },
      }
    )
  else
    {};

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
  cilium_values: params.cilium_helm_values,
  values:
    if !std.member([ 'opensource', 'enterprise' ], params.release) then
      error 'Unknown release type "%s". Supported values are "opensource" and "enterprise".' % params.release
    else
      helm_values[params.release] + com.makeMergeable(params.helm_values),
}
