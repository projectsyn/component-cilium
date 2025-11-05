local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;
local isOpenshift = std.member([ 'openshift4', 'oke' ], inv.parameters.facts.distribution);

// Parse cilium version

local parse_version(ver) =
  local verparts = std.split(ver, '.');
  local parseOrError(val, typ) =
    local parsed = std.parseJson(val);
    if std.isNumber(parsed) then
      parsed
    else
      error
        'Failed to parse %s version "%s" as number' % [
          typ,
          val,
        ];
  {
    major: parseOrError(verparts[0], 'major'),
    minor: parseOrError(verparts[1], 'minor'),
  };

local version = parse_version(
  if params.install_method == 'helm' then
    local chart = if params.release == 'opensource'
    then
      'cilium'
    else
      'cilium-enterprise';
    params.charts[chart].version
  else
    params.olm.full_version
);

// CiliumLoadBalancerIPPool

local CiliumLoadBalancerIPPool(name) =
  kube._Object('cilium.io/v2alpha1', 'CiliumLoadBalancerIPPool', name) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true',
      },
    },
  };

local render_ip_pool(name, pool) =
  {
    spec: {
      [if version.minor <= 14 then 'cidrs' else 'blocks']:
        std.objectValues(pool.blocks),
      serviceSelector: std.get(pool, 'serviceSelector', {}),
    } + com.makeMergeable(std.get(pool, 'spec', {})),
  };

local render_ip_pools(pools) = com.generateResources(
  std.mapWithKey(render_ip_pool, pools),
  CiliumLoadBalancerIPPool,
);


{
  isOpenshift: isOpenshift,
  version: version,
  ipPool: render_ip_pools,
}
