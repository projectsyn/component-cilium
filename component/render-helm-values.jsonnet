local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.cilium;

local helm_values = {
  opensource: params.cilium_helm_values,
  enterprise: {
    cilium: params.cilium_helm_values,
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
