// main template for cilium
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local util = import 'util.libsonnet';

local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.cilium;

local additionalMeta =
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
    {
      labels+: {
        'pod-security.kubernetes.io/audit': 'privileged',
        'pod-security.kubernetes.io/enforce': 'privileged',
        'pod-security.kubernetes.io/warn': 'privileged',
      },
    };

assert
  params._namespace != 'cilium' == params._want_nonstandard_namespace
  : 'If you want to deploy Cilium to a namespace other than `cilium`, '
    + 'you must set component parameter `_want_nonstandard_namespace` to `true`!';

if params._namespace == 'kube-system' then
  std.trace(
    'User requested deploying Cilium to `kube-system`, not generating namespace manifest',
    {}
  )
else
  {
    '00_cilium_namespace': kube.Namespace(params._namespace) {
      metadata+: additionalMeta,
    },
  }
