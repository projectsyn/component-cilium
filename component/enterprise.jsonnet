local kap = import 'lib/kapitan.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local icr_config = import 'icr-config.libsonnet';

if params.release == 'enterprise' then
  {
    ['80_enterprise_%s' % k]: icr_config[k]
    for k in std.objectFields(icr_config)
  }
else
  {}
