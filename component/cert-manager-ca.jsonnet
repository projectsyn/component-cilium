local cm = import 'lib/cert-manager.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.cilium;

local has_cert_manager = std.member(inv.applications, 'cert-manager');

local self_signed_issuer = cm.issuer('self-signed') {
  metadata+: {
    namespace: params._namespace,
  },
  spec: {
    selfSigned: {},
  },
};

local ca_cert = cm.cert('cilium-ca') {
  metadata+: {
    namespace: params._namespace,
  },
  spec: {
    isCA: true,
    // Make CA cert valid for 2 years. The Helm chart generates the Hubble
    // certs with a lifetime of 1 year.
    duration: '%dh' % (2 * 365 * 24),
    // renew 4 months before expiry
    renewBefore: '%dh' % (120 * 24),
    commonName: 'cilium-ca',
    secretName: 'cilium-ca',
    privateKey: {
      algorithm: 'ECDSA',
      size: 256,
    },
    issuerRef: {
      name: 'self-signed',
      kind: 'Issuer',
      group: 'cert-manager.io',
    },
  },
};

local ca_issuer = cm.issuer('cilium-ca') {
  metadata+: {
    namespace: params._namespace,
  },
  spec: {
    ca: {
      secretName: ca_cert.spec.secretName,
    },
  },
};

if params.deploy_cert_manager_ca then (
  if !has_cert_manager then
    error '\n\n[cilium] Parameter `deploy_cert_manager_ca` requires component cert-manager to be present on target cluster.'
  else {
    '20_cilium_ca': [
      self_signed_issuer,
      ca_cert,
      ca_issuer,
    ],
  }
) else {}
