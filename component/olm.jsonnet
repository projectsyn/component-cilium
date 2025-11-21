// main template for cilium
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.cilium;

local helm = import 'render-helm-values.jsonnet';
local util = import 'util.libsonnet';

// NOTE(sg): We introduce hidden parameter `__mock_enterprise` which can be
// set to `true` in test cases to test `params.release == enterprise` behavior
// while downloading the opensource OLM tarball (see test case
// `enterprise-bgp` for an example).
// Notably, we must override this for most of the OLM processing, since we're
// using the opensource OLM manifests for the mock enterprise test.
local mock_enterprise = std.get(params, '__mock_enterprise', false);
local release = if mock_enterprise then
  'opensource'
else
  params.release;

local olmDir =
  local prefix = '%s/olm/cilium/cilium-olm/' % inv.parameters._base_directory;
  if release == 'opensource' then
    prefix +
    'cilium.v%s/olm-for-cilium-main/manifests/cilium.v%s/' %
    [ params.olm.full_version, params.olm.full_version ]
  else if release == 'enterprise' then
    // The component now generates this directory itself when unpacking the
    // tarball, since Cilium 1.17 (CLife) doesn't have a directory in the
    // tarball anymore.
    local manifests_dir = 'cilium.v%s/' % params.olm.full_version;
    local path_variants = [
      // Cilium 1.17 (CLife) doesn't have a directory in the tarball anymore
      '',
      // Cilium <= 1.16 has a directory matching `manifests_dir` in the
      // tarball.
      manifests_dir,
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
    error "Unknown release '%s'" % [ release ];

local patchDeploymentContainerName =
  // for the mock enterprise OLM test for 1.17 and newer, we patch the OLM
  // deployment to use container name `manager` so the OLM enterprise
  // deployment patching logic applies.
  if mock_enterprise && util.manifestsVersion.minor >= 17 then
    {
      spec+: {
        template+: {
          spec+: {
            containers: [
              super.containers[0] {
                name: 'manager',
              },
            ],
          },
        },
      },
    }
  else
    {};

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
      contents:
        local c = std.parseJson(kap.yaml_load(olmDir + name));
        if c.kind == 'Deployment' then c + patchDeploymentContainerName else c,
    },
    kap.dir_files_list(olmDir)
  ),
  {
    files:
      if mock_enterprise && util.manifestsVersion.minor <= 16 then [
        {
          filename: 'cluster-network-06-cilium-00002-cilium-ee-olm-overrides-configmap.yaml',
          contents: {
            apiVersion: 'v1',
            kind: 'ConfigMap',
            metadata: {
              labels: {
                name: 'cilium-ee-olm',
              },
              name: 'cilium-ee-olm-overrides',
              namespace: 'cilium',
            },

          },
        },
      ]
      else [],
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
  enterprise: if util.manifestsVersion.minor >= 17 then {
    CiliumConfig: 'ciliumconfig',
    Deployment: 'clife-controller-manager',
    OlmClusterRole: 'clife-manager-role',
  } else {
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
            // CLife container name is `manager`, cilium-ee-olm container name
            // is `operator`.
            if c.name == 'operator' || c.name == 'manager' then
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
                  // for CLife we need to patch the Deployment env vars, since
                  // the overrides configmap doesn't exist anymore.
                  if c.name == 'manager' || params.release == 'opensource' then
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
  local clusterPoolIPv4MaskSizePatch =
    local patch = {
      ipam+: if util.version.minor >= 16 then {
        operator+: {
          clusterPoolIPv4MaskSize:
            if std.isString(super.clusterPoolIPv4MaskSize) then
              std.trace(
                '`clusterPoolIPv4MaskSize` must be an integer for Cilium >= 1.16, converting from string',
                std.parseInt(super.clusterPoolIPv4MaskSize)
              )
            else
              super.clusterPoolIPv4MaskSize,
        },
      } else {},
    };
    // NOTE(sg): This is explicitly `params.relase` since we don't want the
    // fall back to the opensource logic for the __mock_enterprise=true test
    // cases.
    // NOTE(sg): CLife (1.17+) doesn't nest the Cilium Helm values in
    // top-level key `spec.cilium` anymore.
    if util.manifestsVersion.minor <= 16 && params.release == 'enterprise' then {
      cilium+: patch,
    } else
      patch;
  if (
    file.contents.kind == 'CiliumConfig'
    && file.contents.metadata.name == metadata_name_map[release].CiliumConfig
    // CiliumConfig is cluster-scoped for Cilium >= 1.17
    && std.get(file.contents.metadata, 'namespace', 'cilium') == 'cilium'
  ) then
    file {
      contents+: {
        spec: helm.values + clusterPoolIPv4MaskSizePatch,
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
    && file.contents.metadata.name == metadata_name_map[release].Deployment
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
                if d.name == metadata_name_map[release].Deployment then
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
    // OLM role doesn't exist for CLife OLM operator (1.17+) -> drop the
    // opensource OLM role file for the olm-enterprise tests
    mock_enterprise &&
    util.manifestsVersion.minor >= 17 &&
    file.contents.kind == 'Role' &&
    file.contents.metadata.namespace == 'cilium' &&
    file.contents.metadata.name == metadata_name_map.opensource.OlmRole
  ) then
    null
  else if (
    // OLM role needs to be patched for Cilium <= 1.16
    util.manifestsVersion.minor <= 16 &&
    file.contents.kind == 'Role' &&
    file.contents.metadata.namespace == 'cilium' &&
    file.contents.metadata.name == metadata_name_map[release].OlmRole
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
        ] + [
          // Grant OLM operator permission to manage cert-manager certificate
          // resources. This is required when setting `method: certmanager`
          // for some Cilium TLS configuration (e.g. Hubble TLS).
          {
            apiGroups: [ 'cert-manager.io' ],
            resources: [ 'certificates' ],
            verbs: [
              'create',
              'delete',
              'deletecollection',
              'get',
              'list',
              'patch',
              'update',
              'watch',
            ],
          },
        ],
      },
    }
  else if (
    util.manifestsVersion.minor <= 16 &&
    file.contents.kind == 'ClusterRole' &&
    file.contents.metadata.name == metadata_name_map[release].OlmClusterRole
  ) then
    file {
      contents+: {
        rules+: [
          {
            apiGroups: [ 'coordination.k8s.io' ],
            resources: [ 'leases' ],
            verbs: [ 'create', 'get', 'update', 'list', 'delete' ],
          },
        ],
      },
    }
  else if (
    util.manifestsVersion.minor >= 17 &&
    file.contents.kind == 'Namespace' &&
    file.contents.metadata.name == 'cilium'
  ) then
    file {
      contents+: {
        metadata+: {
          annotations+: {
            'openshift.io/node-selector': '',
          },
        },
      },
    }
  else
    file;

local migrate_to_clife = params.olm.migrate_to_clife;

std.foldl(
  function(files, file) files { [std.strReplace(file.filename, '.yaml', '')]: file.contents },
  std.filter(
    function(obj) obj != null,
    std.map(function(obj) patchManifests(obj, olmFiles.has_csv), olmFiles.files),
  ),
  {
    [if util.manifestsVersion.minor >= 17 && migrate_to_clife then '97_migrate_to_clife']:
      import 'olm-migrate-operator.libsonnet',
    '99_cleanup': (import 'cleanup.libsonnet'),
  }
)
