local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local CiliumL2AnnouncementPolicy(name) =
  kube._Object('cilium.io/v2alpha1', 'CiliumL2AnnouncementPolicy', name) {
    metadata+: {
      annotations+: {
        'argocd.argoproj.io/sync-options': 'SkipDryRunOnMissingResource=true,Prune=false',
      },
    },
  };

local policies = com.generateResources(
  params.l2_announcements.policies,
  CiliumL2AnnouncementPolicy
);

{
  [if params.l2_announcements.enabled && std.length(params.l2_announcements.policies) > 0 then
    '50_l2_announcement_policies']: policies,
}
