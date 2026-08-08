#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
flux_version="${FLUX_VERSION:-v2.7.2}"
kubernetes_version="${KUBERNETES_VERSION:-1.35.0}"
schema_root="$(mktemp -d)"

cleanup() {
  rm -rf -- "${schema_root}"
}
trap cleanup EXIT

for command in curl git kubeconform kustomize tar yq; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "ERROR: ${command} is required" >&2
    exit 1
  fi
done

echo "INFO: validating YAML syntax"
while IFS= read -r -d '' file; do
  yq eval 'true' "${repo_root}/${file}" >/dev/null
done < <(git -C "${repo_root}" ls-files -z '*.yaml' '*.yml')

flux_schema_dir="${schema_root}/master-standalone-strict"
mkdir -p "${flux_schema_dir}"

echo "INFO: downloading Flux ${flux_version} schemas"
curl --fail --silent --show-error --location \
  "https://github.com/fluxcd/flux2/releases/download/${flux_version}/crd-schemas.tar.gz" \
  | tar -xz -C "${flux_schema_dir}"

kubernetes_schema_flags=(
  -strict
  -ignore-missing-schemas
  -kubernetes-version "${kubernetes_version}"
  -schema-location default
  -summary
)

flux_schema_flags=(
  -strict
  -schema-location "${flux_schema_dir}/all.json"
  -summary
)

echo "INFO: rendering and validating Kustomize overlays"
while IFS= read -r -d '' file; do
  overlay="${repo_root}/${file%/kustomization.yaml}"
  rendered="${schema_root}/rendered.yaml"
  flux_resources="${schema_root}/flux-resources.yaml"
  echo "INFO: validating ${file%/kustomization.yaml}"
  kustomize build "${overlay}" --load-restrictor=LoadRestrictionsNone >"${rendered}"
  kubeconform "${kubernetes_schema_flags[@]}" "${rendered}"

  yq eval-all \
    'select(.apiVersion != null and (.apiVersion | test("toolkit\\.fluxcd\\.io/")))' \
    "${rendered}" >"${flux_resources}"
  if [[ -s "${flux_resources}" ]]; then
    kubeconform "${flux_schema_flags[@]}" "${flux_resources}"
  fi
done < <(git -C "${repo_root}" ls-files -z '*/kustomization.yaml')

echo "INFO: all manifests passed validation"
