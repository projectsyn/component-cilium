// main template for cilium
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.cilium;

local helm = import 'render-helm-values.jsonnet';
local util = import 'util.libsonnet';

local olmDir =
  local prefix = '%s/olm/cilium/cilium-olm/' % inv.parameters._base_directory;
  if params.release == 'opensource' then
    prefix + 'olm-for-cilium-main/manifests/cilium.v%s/' % params.olm.full_version
  else if params.release == 'enterprise' then
    local path_variants = [
      // Known releases: 1.11.5, 1.12.6
      '',
      // Known releases: 1.11.17
      'tmp/cilium-ee-olm/manifests/',
      // Known releases: 1.13.2
      'cilium-ee-olm/manifests/',
    ];
    local manifests_dir = 'cilium.v%s/' % params.olm.full_version;
    local dir = std.foldl(
      function(curr, variant)
        local cand = prefix + variant + manifests_dir;
        if kap.file_exists(cand).exists then
          cand
        else
          curr,
      path_variants,
      null
    );
    if dir == null then
      error
        'Unable to find manifests path for Cilium EE %s. ' % params.olm.full_version
        + 'Check structure of .tar.gz and update component.'
    else
      dir
  else
    error "Unknown release '%s'" % [ params.release ];

local olmFiles = std.foldl(
  function(status, file)
    status {
      files+: [ file ],
      has_csv: status.has_csv || (file.contents.kind == 'ClusterServiceVersion'),
    },

  std.filterMap(
    function(name)
      // drop hidden files
      !std.startsWith(name, '.'),
    function(name) {
      filename: name,
      contents: std.parseJson(kap.yaml_load(olmDir + name)),
    },
    kap.dir_files_list(olmDir)
  ),
  {
    files: [],
    has_csv: false,
  }
);

local metadata_name_map = {
  opensource: {
    CiliumConfig: 'cilium',
    Deployment: 'cilium-olm',
    OlmRole: 'cilium-olm',
    OlmClusterRole: 'cilium-cilium-olm',
  },
  enterprise: {
    CiliumConfig: 'cilium-enterprise',
    Deployment: 'cilium-ee-olm',
    OlmRole: 'cilium-ee-olm',
    OlmClusterRole: 'cilium-cilium-ee-olm',
  },
};

local patchManifests = function(file, has_csv)
  local hasK8sHost = std.objectHas(helm.cilium_values, 'k8sServiceHost');
  local hasK8sPort = std.objectHas(helm.cilium_values, 'k8sServicePort');
  local deploymentPatch = {
    spec+: {
      template+: {
        spec+: {
          containers: [
            if c.name == 'operator' then
              c {
                resources+: params.olm.resources,
                command: [
                  cmd
                  for cmd in super.command
                  if cmd != '--zap-devel'
                ] + [
                  '--zap-log-level=%s' % params.olm.log_level,
                ],
                env+:
                  if params.release == 'opensource' then
                    (
                      if hasK8sHost then
                        [
                          {
                            name: 'KUBERNETES_SERVICE_HOST',
                            value: helm.cilium_values.k8sServiceHost,
                          },
                        ]
                      else []
                    ) + (
                      if hasK8sPort then
                        [
                          {
                            name: 'KUBERNETES_SERVICE_PORT',
                            value: helm.cilium_values.k8sServicePort,
                          },
                        ]
                      else []
                    )
                  else [],
              }
            else
              c
            for c in super.containers
          ],
        },
      },
    },
  };
  if (
    file.contents.kind == 'CiliumConfig'
    && file.contents.metadata.name == metadata_name_map[params.release].CiliumConfig
    && file.contents.metadata.namespace == 'cilium'
  ) then
    file {
      contents+: {
        spec: helm.values,
      },
    }
  else if (
    params.release == 'enterprise'
    && file.contents.kind == 'ConfigMap'
    && file.contents.metadata.name == 'cilium-ee-olm-overrides'
    && file.contents.metadata.namespace == 'cilium'
  ) then
    file {
      contents+: {
        data+: {
          [if hasK8sHost then 'KUBERNETES_SERVICE_HOST']:
            helm.cilium_values.k8sServiceHost,
          [if hasK8sPort then 'KUBERNETES_SERVICE_PORT']:
            helm.cilium_values.k8sServicePort,
        },
      },
    }
  else if (
    file.contents.kind == 'Deployment'
    && file.contents.metadata.name == metadata_name_map[params.release].Deployment
    && file.contents.metadata.namespace == 'cilium'
  ) then
    file {
      contents+: deploymentPatch,
    }
  else if (
    file.contents.kind == 'ClusterServiceVersion' &&
    file.contents.metadata.namespace == 'cilium'
  ) then
    file {
      contents+: {
        spec+: {
          install+: {
            spec+: {
              deployments: [
                if d.name == metadata_name_map[params.release].Deployment then
                  d + deploymentPatch
                else
                  d
                for d in super.deployments
              ],
            },
          },
        },
      },
    }
  else if (
    file.contents.kind == 'Subscription' &&
    file.contents.metadata.namespace == 'cilium'
  ) then
    null
  else if (
    !has_csv &&
    file.contents.kind == 'OperatorGroup' &&
    file.contents.metadata.namespace == 'cilium'
  ) then
    null
  else if (
    file.contents.kind == 'Role' &&
    file.contents.metadata.namespace == 'cilium' &&
    file.contents.metadata.name == metadata_name_map[params.release].OlmRole
  ) then
    file {
      contents+: {
        rules: [
          if
            r.apiGroups == [ '' ]
            && r.resources == [ 'events' ]
            && !std.member(r.verbs, 'patch')
          then
            r {
              verbs+: [ 'patch' ],
            }
          else
            r
          for r in super.rules
        ],
      },
    }
  else if (
    file.contents.kind == 'ClusterRole' &&
    file.contents.metadata.name == metadata_name_map[params.release].OlmClusterRole
  ) then
    file {
      contents+: {
        rules+: [ {
          apiGroups: [ 'coordination.k8s.io' ],
          resources: [ 'leases' ],
          verbs: [ 'create', 'get', 'update', 'list', 'delete' ],
        } ],
      },
    }
  else
    file;

local kubeSystemSecretRO = [
  kube.Role(metadata_name_map[params.release].OlmRole) {
    metadata+: {
      namespace: 'kube-system',
    },
    rules: [
      {
        apiGroups: [ '' ],
        resources: [ 'secrets' ],
        verbs: [ 'get', 'list', 'watch' ],
      },
    ],
  },
  kube.RoleBinding(metadata_name_map[params.release].OlmRole) {
    metadata+: {
      namespace: 'kube-system',
    },
    roleRef: {
      apiGroup: 'rbac.authorization.k8s.io',
      kind: 'Role',
      name: metadata_name_map[params.release].OlmRole,
    },
    subjects: [
      {
        kind: 'ServiceAccount',
        namespace: 'cilium',
        name: metadata_name_map[params.release].OlmRole,
      },
    ],
  },
];

std.foldl(
  function(files, file) files { [std.strReplace(file.filename, '.yaml', '')]: file.contents },
  std.filter(
    function(obj) obj != null,
    std.map(function(obj) patchManifests(obj, olmFiles.has_csv), olmFiles.files),
  ),
  {
    [if util.version.minor <= 14 then '98_fixup_bgp_controlpane_rbac']: kubeSystemSecretRO,
    '99_cleanup': (import 'cleanup.libsonnet'),
  }
)
