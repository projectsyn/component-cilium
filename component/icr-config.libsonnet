local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local util = import 'util.libsonnet';

local esp = import 'lib/espejote.libsonnet';
local eso = import 'lib/external-secrets-operator.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local pull_secret_name = 'cilium-pull-secret';

local credentials_type =
  local t = params.enterprise.registry.credentials.type;
  if std.member([ 'static', 'direct-eso', 'projectsyn' ], t) then
    t
  else
    error "The component only supports enterprise credentials types 'static', 'direct-eso', and 'projectsyn'; Got %s." % t;

local pull_secret_managed_resource(syn) =
  local rbac_name = 'cilium-pull-secret-manager';
  local sa = kube.ServiceAccount(rbac_name) {
    metadata+: {
      namespace: 'openshift-config',
    },
  };
  local role = kube.Role(rbac_name) {
    metadata+: {
      namespace: 'openshift-config',
    },
    rules: [
      {
        apiGroups: [ '' ],
        resources: [ 'secrets' ],
        resourceNames: [ pull_secret_name ],
        verbs: [ 'get', 'list', 'watch', 'create', 'update', 'patch' ],
      },
      {
        apiGroups: [ '' ],
        resources: [ 'secrets' ],
        resourceNames: [ 'isovalent-registry-config' ],
        verbs: [ 'get', 'list', 'watch' ],
      },
    ],
  };
  local syn_role = kube.Role(rbac_name) {
    metadata+: {
      namespace: 'syn',
    },
    rules: [
      {
        apiGroups: [ '' ],
        resources: [ 'secrets' ],
        resourceNames: [ 'steward' ],
        verbs: [ 'get', 'list', 'watch' ],
      },
    ],
  };
  local rolebinding = kube.RoleBinding(rbac_name) {
    metadata+: {
      namespace: 'openshift-config',
    },
    roleRef_: role,
    subjects_: [ sa ],
  };
  local syn_rolebinding = kube.RoleBinding(rbac_name) {
    metadata+: {
      namespace: 'syn',
    },
    roleRef_: syn_role,
    subjects_: [ sa ],
  };
  [
    esp.managedResource('cilium-pull-secret', 'openshift-config') {
      spec: {
        applyOptions: {
          // NOTE(sg): We set apply option force=true, so that the
          // managedresource can properly revert external changes to the
          // target secret.
          force: true,
        },
        serviceAccountRef: {
          name: sa.metadata.name,
        },
        context: [
          {
            name: 'cilium_pull_secret',
            resource: {
              apiVersion: 'v1',
              kind: 'Secret',
              name: pull_secret_name,
              namespace: 'openshift-config',
            },
          },
          {
            name: 'isovalent_registry_config',
            resource: {
              apiVersion: 'v1',
              kind: 'Secret',
              name: 'isovalent-registry-config',
              namespace: 'openshift-config',
            },
          },
        ] + if syn then [
          {
            name: 'steward_token',
            resource: {
              apiVersion: 'v1',
              kind: 'Secret',
              name: 'steward',
              namespace: 'syn',
            },
          },
        ] else [],
        triggers: [
          {
            name: 'cilium_pull_secret',
            watchContextResource: {
              name: 'cilium_pull_secret',
            },
          },
          {
            name: 'isovalent_registry_config',
            watchContextResource: {
              name: 'isovalent_registry_config',
            },
          },
        ] + if syn then [
          {
            name: 'steward_token',
            watchContextResource: {
              name: 'steward_token',
            },
          },
        ] else [],
        template: importstr 'espejote-templates/cilium-pull-secret.jsonnet',
      },
    },
    sa,
    role,
    rolebinding,
  ] + if syn then [ syn_role, syn_rolebinding ] else [];

local pull_secret_bootstrap_job =
  local rbac_name = 'cilium-pull-secret-bootstrapper';
  local sa = kube.ServiceAccount(rbac_name) {
    metadata+: {
      namespace: 'openshift-config',
    },
  };
  local role = kube.Role(rbac_name) {
    metadata+: {
      namespace: 'openshift-config',
    },
    rules: [
      {
        apiGroups: [ '' ],
        resources: [ 'secrets' ],
        resourceNames: [ 'isovalent-registry-config' ],
        verbs: [ 'get', 'list', 'watch' ],
      },
      {
        apiGroups: [ '' ],
        resources: [ 'secrets' ],
        resourceNames: [ pull_secret_name ],
        verbs: [ 'get', 'list', 'watch', 'create', 'update', 'patch' ],
      },
    ],
  };
  local rolebinding = kube.RoleBinding(rbac_name) {
    metadata+: {
      namespace: 'openshift-config',
    },
    roleRef_: role,
    subjects_: [ sa ],
  };
  [
    kube.Secret('isovalent-registry-config') {
      metadata+: {
        namespace: 'openshift-config',
      },
      stringData: {
        access_token: params.enterprise.registry.credentials.access_token,
        'pull_secret_template.yaml': std.manifestJsonMinified({
          apiVersion: 'v1',
          kind: 'Secret',
          metadata: {
            labels: {
              'external-secrets.io/type': 'webhook',
            },
          },
          type: 'kubernetes.io/dockerconfigjson',
          stringData: {
            '.dockerconfigjson': '{}',
          },
        }),
      },
    },
    kube.Job('bootstrap-cilium-pull-secret') {
      metadata+: {
        namespace: 'openshift-config',
        annotations+: {
          'argocd.argoproj.io/hook': 'Sync',
        },
      },
      spec+: {
        activeDeadlineSeconds: 30,
        backoffLimit: 1,
        template+: {
          spec+: {
            serviceAccountName: sa.metadata.name,
            containers_: {
              bootstrap: kube.Container('pull-secret-bootstrap') {
                image: '%(registry)s/%(repository)s:%(tag)s' % params.images.oc,
                command: [
                  'bash',
                  '-c',
                  |||
                    if ! kubectl -n "${NAMESPACE}" get secret "${PULL_SECRET}" &>/dev/null; then
                      echo "Creating initial secret '${PULL_SECRET}'"
                      yq '.metadata.name=strenv(PULL_SECRET) | .stringData.access_token=strenv(ACCESS_TOKEN)' \
                        /config/pull_secret_template.yaml \
                        | kubectl -n "${NAMESPACE}" apply --server-side -f-
                    else
                      echo "Secret '${PULL_SECRET}' already exists, nothing to do."
                    fi
                  |||,
                ],
                env_: {
                  NAMESPACE: {
                    fieldRef: {
                      fieldPath: 'metadata.namespace',
                    },
                  },
                  PULL_SECRET: pull_secret_name,
                  ACCESS_TOKEN: {
                    secretKeyRef: {
                      name: 'isovalent-registry-config',
                      key: 'access_token',
                    },
                  },
                },
                volumeMounts_: {
                  config: {
                    mountPath: '/config',
                  },
                },
              },
            },
            volumes_: {
              config: {
                secret: {
                  secretName: 'isovalent-registry-config',
                  items: [
                    {
                      key: 'pull_secret_template.yaml',
                      path: 'pull_secret_template.yaml',
                      mode: std.parseOctal('0600'),
                    },
                  ],
                },
              },
            },
          },
        },
      },
    },
    sa,
    role,
    rolebinding,
  ];

local ocp_credentials_manifests = {
  static: {
    assert std.member(inv.applications, 'espejote') : 'Static Isovalent registry credentials management requires Espejote',
    pull_secret_config: kube.Secret('isovalent-registry-config') {
      metadata+: {
        namespace: 'openshift-config',
      },
      stringData: {
        pull_secret_name: pull_secret_name,
        hostname: params.enterprise.registry.hostname,
        username: params.enterprise.registry.credentials.username,
        access_token: params.enterprise.registry.credentials.access_token,
      },
    },
    // NOTE(sg): we need the ManagedResource here, because we can't precompute
    // the base64-encoded pull secret contents which are based on Vault
    // references in Commodore.
    pull_secret_managed_resource: pull_secret_managed_resource(syn=false),
  },
  'direct-eso': {
    assert std.member(inv.applications, 'external-secrets-operator') : 'Isovalent registry credentials management  type `direct-eso` requires External Secrets Operator',
    assert params.enterprise.registry.hostname == 'containers.isovalent.com' : 'Isovalent registry credentials management type `direct-eso` is only supported for registry hostname containers.isovalent.com',
    pull_secret_bootstrap_job: pull_secret_bootstrap_job,
    pull_secret_eso: [
      eso._Generator('Webhook', 'registry-isovalent-com') {
        metadata+: {
          namespace: 'openshift-config',
        },
        spec: {
          url: 'https://registry.isovalent.com/access/api/v1/tokens',
          result: {
            jsonPath: '$',
          },
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: 'Bearer {{ print .pull.access_token }}',
          },
          body: std.manifestJsonMinified({
            description: '%s_pull-secret' % inv.parameters.cluster.name,
            token_type: 'access_token',
          }),
          secrets: [
            {
              name: 'pull',
              secretRef: {
                name: pull_secret_name,
              },
            },
          ],
        },
      },
      eso.ExternalSecret('cilium-pull-secret') {
        metadata+: {
          namespace: 'openshift-config',
        },
        spec: {
          refreshInterval: '720h',  // 30 days
          target: {
            creationPolicy: 'Owner',
            deletionPolicy: 'Retain',
            name: pull_secret_name,
            template: {
              metadata: {
                labels: {
                  'pull-secret.openshift-config.syn.tools/include': '',
                  'external-secrets.io/type': 'webhook',
                },
              },
              data: {
                access_token: '{{ print .access_token }}',
                '.dockerconfigjson': |||
                  {
                    "auths": {
                      "containers.isovalent.com": {
                        "auth": "{{ printf "%s:%s" .username .access_token | b64enc }}"
                      }
                    }
                  }
                |||,
              },
              engineVersion: 'v2',
              mergePolicy: 'Replace',
              type: 'kubernetes.io/dockerconfigjson',
            },
          },
          dataFrom: [ {
            sourceRef: {
              generatorRef: {
                apiVersion: 'generators.external-secrets.io/v1alpha1',
                kind: 'Webhook',
                name: 'registry-isovalent-com',
              },
            },
          } ],
        },
      },
    ],
  },
  projectsyn: {
    assert std.member(inv.applications, 'espejote') : 'Project Syn-aware Isovalent registry credentials management requires Espejote',
    assert params.enterprise.registry.hostname != 'containers.isovalent.com' : 'Project Syn-aware Isovalent registry credentials management requires a Project-Syn managed pull through registry for containers.isovalent.com',
    pull_secret_config: kube.Secret('isovalent-registry-config') {
      metadata+: {
        namespace: 'openshift-config',
      },
      stringData: {
        pull_secret_name: pull_secret_name,
        hostname: params.enterprise.registry.hostname,
        username: params.enterprise.registry.credentials.username,
      },
    },
    pull_secret_managed_resource: pull_secret_managed_resource(syn=true),
  },
};

local registry_mirror =
  if params.enterprise.registry.hostname != 'containers.isovalent.com' then
    {
      isovalent_registry_mirror_config: [
        kube._Object(
          'config.openshift.io/v1',
          'ImageTagMirrorSet',
          'containers-isovalent-com'
        ) {
          spec: {
            imageTagMirrors: [ {
              mirrorSourcePolicy: 'NeverContactSource',
              mirrors: [ params.enterprise.registry.hostname ],
              source: 'containers.isovalent.com',
            } ],
          },
        },
        kube._Object(
          'config.openshift.io/v1',
          'ImageDigestMirrorSet',
          'containers-isovalent-com'
        ) {
          spec: {
            imageDigestMirrors: [ {
              mirrorSourcePolicy: 'NeverContactSource',
              mirrors: [ params.enterprise.registry.hostname ],
              source: 'containers.isovalent.com',
            } ],
          },
        },
      ],
    }
  else
    {};

if !util.isOpenshift then
  error 'Isovalent credentials management NYI for non-OpenShift'
else
  ocp_credentials_manifests[credentials_type]
  + registry_mirror
