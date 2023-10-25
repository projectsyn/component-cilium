local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local CiliumEgressGatewayPolicy(name) =
  kube._Object('cilium.io/v2', 'CiliumEgressGatewayPolicy', name);


local policies = com.generateResources(
  params.egress_gateway.policies,
  CiliumEgressGatewayPolicy
);

{
  [if params.egress_gateway.enabled && std.length(params.egress_gateway.policies) > 0 then
    '20_egress_gateway_policies']: policies,
}
