local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local CiliumLoadBalancerIPPool(name) =
  kube._Object('cilium.io/v2alpha1', 'CiliumLoadBalancerIPPool', name) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true',
      },
    },
  };

local CiliumBGPPeeringPolicy(name) =
  kube._Object('cilium.io/v2alpha1', 'CiliumBGPPeeringPolicy', name) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true',
      },
    },
  };

local render_peering(name, peering) =
  local render_vrouter(config) = config {
    neighbors: std.objectValues(std.mapWithKey(
      function(peerAddr, n) n {
        peerAddress: peerAddr,
      },
      super.neighbors
    )),
  };
  {
    spec: {
      nodeSelector: std.get(peering, 'nodeSelector', {}),
      virtualRouters: std.map(
        render_vrouter,
        std.objectValues(peering.virtualRouters)
      ),
    } + com.makeMergeable(std.get(peering, 'spec', {})),
  };

local peerings = com.generateResources(
  std.mapWithKey(render_peering, params.bgp.peerings),
  CiliumBGPPeeringPolicy
);

local render_ip_pool(name, pool) =
  {
    spec: {
      cidrs: std.objectValues(pool.cidrs),
      serviceSelector: std.get(pool, 'serviceSelector', {}),
    } + com.makeMergeable(std.get(pool, 'spec', {})),
  };

local lb_ip_pools = com.generateResources(
  std.mapWithKey(render_ip_pool, params.bgp.loadbalancer_ip_pools),
  CiliumLoadBalancerIPPool,
);

{
  [if params.bgp.enabled && std.length(peerings) > 0 then
    '40_bgp_peerings']: peerings,
  [if params.bgp.enabled && std.length(lb_ip_pools) > 0 then
    '40_loadbalancer_ip_pools']: lb_ip_pools,
}
