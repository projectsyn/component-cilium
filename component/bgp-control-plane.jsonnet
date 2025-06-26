local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local util = import 'util.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

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

local render_peer_config(name, config) =
  local auth_secret_names = [ o.metadata.name for o in authsecrets ];
  local validate_peer_config(pconfig) =
    local secretname = std.get(pconfig.spec, 'authSecretRef');
    assert
      secretname == null || std.member(auth_secret_names, secretname)
      : "CiliumBGPPeerConfig `%s` references auth secret `%s` which doesn't exist"
        % [ name, secretname ];
    pconfig;
  validate_peer_config({
    metadata+: std.get(config, 'metadata', {}),
    spec: {
      families: std.objectValues(std.get(config, 'families', {})),
    } + com.makeMergeable(std.get(config, 'spec', {})),
  });

local bgppeerconfigs = com.generateResources(
  std.mapWithKey(render_peer_config, params.bgp.peer_configs),
  CiliumBGPPeerConfig
);

local render_cluster_config(name, config) =
  local peerConfigNames = [ o.metadata.name for o in bgppeerconfigs ];
  local validate_peer_config(iname, pconfig) =
    local pcfgname = std.get(pconfig, 'peerConfigRef', { name: '' }).name;
    assert
      std.member(peerConfigNames, pcfgname)
      : 'Peer `%s` in BGP instance `%s` in CiliumBGPClusterConfig `%s` ' %
        [ pconfig.name, iname, name ]
        + "references CiliumBGPPeerConfig `%s` which doesn't exist" %
          [ pcfgname ];
    pconfig;
  local render_instance(name, iconfig) =
    local cfg = iconfig {
      name: name,
      peers: [
        validate_peer_config(name, iconfig.peers[pname] { name: pname })
        for pname in std.objectFields(iconfig.peers)
      ],
    };
    cfg;
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


local lb_ip_pools = util.ipPool(params.bgp.loadbalancer_ip_pools);

{
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
