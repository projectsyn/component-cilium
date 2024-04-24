local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.cilium;

{
  cilium_values: params.cilium_helm_values,
  values: params.helm_values,
}
