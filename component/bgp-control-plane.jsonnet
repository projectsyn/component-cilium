local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local util = import 'util.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local CiliumBGPPeeringPolicy(name) =
  kube._Object('cilium.io/v2alpha1', 'CiliumBGPPeeringPolicy', name) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true',
      },
    },
  };

local CiliumBGPClusterConfig(name) =
  kube._Object('cilium.io/v2alpha1', 'CiliumBGPClusterConfig', name) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true',
      },
    },
    spec: {},
  };

local CiliumBGPPeerConfig(name) =
  kube._Object('cilium.io/v2alpha1', 'CiliumBGPPeerConfig', name) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true',
      },
    },
    spec: {},
  };

local CiliumBGPAdvertisement(name) =
  kube._Object('cilium.io/v2alpha1', 'CiliumBGPAdvertisement', name) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true',
      },
    },
    spec: {},
  };

local CiliumBGPNodeConfigOverride(name) =
  kube._Object('cilium.io/v2alpha1', 'CiliumBGPNodeConfigOverride', name) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true',
      },
    },
    spec: {},
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
  std.trace(
    'CiliumBGPPeeringPolicy is deprecated. ' +
    'We recommend migrating to BGPv2, see https://hub.syn.tools/cilium/TODO',
    CiliumBGPPeeringPolicy
  )
);

local render_cluster_config(name, config) =
  local render_instance(name, iconfig) = iconfig {
    name: name,
    peers: [
      iconfig.peers[name] { name: name }
      for name in std.objectFields(iconfig.peers)
    ],
  };
  {
    metadata+: std.get(config, 'metadata', {}),
    spec: {
      nodeSelector: std.get(config, 'nodeSelector', {}),
      bgpInstances: std.objectValues(std.mapWithKey(
        render_instance,
        config.bgpInstances
      )),
    } + com.makeMergeable(std.get(config, 'spec', {})),
  };

local bgpclusterconfigs = com.generateResources(
  std.mapWithKey(render_cluster_config, params.bgp.cluster_configs),
  CiliumBGPClusterConfig
);

local render_peer_config(name, config) =
  {
    metadata+: std.get(config, 'metadata', {}),
    spec: {
      families: std.objectValues(std.get(config, 'families', {})),
    } + com.makeMergeable(std.get(config, 'spec', {})),
  };

local bgppeerconfigs = com.generateResources(
  std.mapWithKey(render_peer_config, params.bgp.peer_configs),
  CiliumBGPPeerConfig
);

local render_advertisement(name, config) =
  {
    metadata+: std.get(config, 'metadata', {}),
    spec: {
      advertisements: std.objectValues(std.get(config, 'advertisements', {})),
    },
  };

local bgpadvertisements = com.generateResources(
  std.mapWithKey(render_advertisement, params.bgp.advertisements),
  CiliumBGPAdvertisement
);

local bgpnodeconfigoverrides = com.generateResources(
  params.bgp.node_config_overrides,
  CiliumBGPNodeConfigOverride
);

local validate_auth_secret(name, config) =
  local data = std.get(config, 'data', {});
  local sdata = std.get(config, 'stringData', {});
  assert
    std.objectHas(data, 'password') || std.objectHas(sdata, 'password')
    : "Cilium BGP auth secret `%s` doesn't have key `password`" % name;
  config;

local authsecrets = com.generateResources(
  std.mapWithKey(validate_auth_secret, params.bgp.auth_secrets),
  kube.Secret
);

local lb_ip_pools = util.ipPool(params.bgp.loadbalancer_ip_pools);

{
  [if params.bgp.enabled && std.length(peerings) > 0 then
    '40_bgp_peerings']: peerings,
  [if params.bgp.enabled && std.length(bgpclusterconfigs) > 0 then
    '40_bgp_cluster_configs']: bgpclusterconfigs,
  [if params.bgp.enabled && std.length(bgppeerconfigs) > 0 then
    '40_bgp_peer_configs']: bgppeerconfigs,
  [if params.bgp.enabled && std.length(bgpadvertisements) > 0 then
    '40_bgp_advertisements']: bgpadvertisements,
  [if params.bgp.enabled && std.length(bgpnodeconfigoverrides) > 0 then
    '40_bgp_node_config_overrides']: bgpnodeconfigoverrides,
  [if params.bgp.enabled && std.length(authsecrets) > 0 then
    '40_bgp_auth_secrets']: authsecrets,
  [if params.bgp.enabled && std.length(lb_ip_pools) > 0 then
    '40_loadbalancer_ip_pools']: lb_ip_pools,
}
