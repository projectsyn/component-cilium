local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.cilium;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('cilium', params.namespace);

{
  cilium: app,
}
