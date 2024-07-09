local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local po = import 'lib/patch-operator.libsonnet';
local util = import 'util.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local fullReplacement = std.member(
  [ 'strict', 'true' ],
  params.cilium_helm_values.kubeProxyReplacement
);


local target = kube._Object('operator.openshift.io/v1', 'Network', 'cluster');

local template = {
  spec: {
    deployKubeProxy: !fullReplacement,
  },
};

local patch = po.Patch(target, template, patchstrategy='application/merge-patch+json');

if util.isOpenshift then
  {
    '99_networkoperator_kube_proxy_patch': patch,
  }
else
  {}
