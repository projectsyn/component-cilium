local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;
local params_upgrade_controller = inv.parameters.openshift_upgrade_controller;

local namespace = params._namespace;
local name = 'cilium-upgrade-approval';

local sa = kube.ServiceAccount(name) {
  metadata+: {
    namespace: params_upgrade_controller.namespace,
  },
};

local role = kube.Role(name) {
  metadata+: {
    namespace: namespace,
  },
  rules: [
    {
      apiGroups: [ 'operators.coreos.com' ],
      resources: [ 'installplans' ],
      verbs: [ 'get', 'list', 'patch' ],
    },
  ],
};

local rolebinding = kube.RoleBinding(name) {
  metadata+: {
    namespace: namespace,
  },
  roleRef_: role,
  subjects_: [ sa ],
};

local scripts = kube.ConfigMap(name) {
  metadata+: {
    namespace: params_upgrade_controller.namespace,
  },
  data: {
    // copied from component-airlock-microgateway
    approve: |||
      #!/bin/bash
      cilium_installplan=$(kubectl -n "${CILIUM_NAMESPACE}" get installplan -ojson | \
        jq -r --argjson upgrade_job "${JOB_metadata_creationTimestamp}" \
          '.items | sort_by(.metadata.creationTimestamp) | reverse
          | [.[] |
             select((.spec.approved != true)
             and (.metadata.creationTimestamp < $upgrade_job))
            ][0] | .metadata.name')

      if [ "${cilium_installplan}" != "null" ]; then
        kubectl patch installplan "${cilium_installplan}" -n "${CILIUM_NAMESPACE}" \
          --type merge --patch '{"spec":{"approved":true}}'
      fi
    |||,
  },
};

local hook = {
  apiVersion: 'managedupgrade.appuio.io/v1beta1',
  kind: 'UpgradeJobHook',
  metadata: {
    name: name,
    namespace: params_upgrade_controller.namespace,
  },
  spec: {
    selector: params.olm.upgrade_strategy.upgrade_job_selector,
    events: [ 'Start' ],
    template: {
      spec: {
        activeDeadlineSeconds: 900,
        template: {
          spec: {
            restartPolicy: 'Never',
            priorityClassName: 'system-cluster-critical',
            serviceAccountName: sa.metadata.name,
            containers: [
              kube.Container('approve') {
                image: '%(registry)s/%(repository)s:%(tag)s' % params.images.oc,
                command: [ '/usr/local/bin/approve' ],
                env_: {
                  CILIUM_NAMESPACE: namespace,
                },
                volumeMounts_: {
                  scripts: {
                    mountPath: '/usr/local/bin/approve',
                    subPath: 'approve',
                    readOnly: true,
                  },
                },
              },
            ],
            volumes: [
              {
                configMap: {
                  defaultMode: std.parseOctal('0550'),
                  name: scripts.metadata.name,
                },
                name: 'scripts',
              },
            ],
          },
        },
      },
    },
  },
};

if !std.member(inv.applications, 'openshift-upgrade-controller') then
  error 'Deploying the upgradejobhook for automated Cilium patch upgrades is only supported on clusters where openshift-upgrade-controller is installed'
else
  [ sa, role, rolebinding, scripts, hook ]
