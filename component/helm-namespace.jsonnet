// main template for cilium
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local util = import 'util.libsonnet';

local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.cilium;

local additionalOpenshiftMeta =
  if util.isOpenshift then
    {
      labels+: {
        'openshift.io/cluster-logging': 'true',
        'openshift.io/cluster-monitoring': 'true',
        'openshift.io/run-level': '0',
      },
      annotations+: {
        'openshift.io/node-selector': '',
      },
    }
  else
    {};

// Define outputs below
{
  '00_cilium_namespace': kube.Namespace(params._namespace) {
    metadata+: additionalOpenshiftMeta,
  },
}
