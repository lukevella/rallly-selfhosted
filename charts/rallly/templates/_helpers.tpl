{{/*
Expand the name of the chart.
*/}}
{{- define "rallly.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "rallly.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "rallly.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "rallly.labels" -}}
helm.sh/chart: {{ include "rallly.chart" . }}
{{ include "rallly.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "rallly.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rallly.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels for the app component specifically. Kubernetes label
selectors do subset matching, so a selector built from rallly.selectorLabels
alone (name+instance) also matches the bundled Postgres/Garage pods, which
carry those same two labels plus their own component label. Anything that
needs to target ONLY the app pods (the app Service, Deployment selector,
PDB, NetworkPolicy) must use this instead.
*/}}
{{- define "rallly.appSelectorLabels" -}}
{{ include "rallly.selectorLabels" . }}
app.kubernetes.io/component: app
{{- end }}

{{- define "rallly.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "rallly.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "rallly.secretName" -}}
{{- default (include "rallly.fullname" .) .Values.existingSecret -}}
{{- end }}

{{- define "rallly.configMapName" -}}
{{ include "rallly.fullname" . }}
{{- end }}

{{- define "rallly.postgresql.fullname" -}}
{{ include "rallly.fullname" . }}-postgresql
{{- end }}

{{- define "rallly.postgresql.secretName" -}}
{{- default (printf "%s-postgresql" (include "rallly.fullname" .)) .Values.postgresql.existingSecret -}}
{{- end }}

{{- define "rallly.garage.fullname" -}}
{{ include "rallly.fullname" . }}-garage
{{- end }}

{{- define "rallly.garage.secretName" -}}
{{- default (printf "%s-garage" (include "rallly.fullname" .)) .Values.garage.existingSecret -}}
{{- end }}

{{- define "rallly.garage.configMapName" -}}
{{ include "rallly.garage.fullname" . }}
{{- end }}

{{/*
Resolve an image reference from a {registry, repository, tag} map, honouring
global.imageRegistry as an override.
*/}}
{{- define "rallly.image" -}}
{{- $registry := .image.registry -}}
{{- if .global.imageRegistry -}}
{{- $registry = .global.imageRegistry -}}
{{- end -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .image.repository .image.tag -}}
{{- else -}}
{{- printf "%s:%s" .image.repository .image.tag -}}
{{- end -}}
{{- end }}

{{/*
Resolve the app image, defaulting the tag to the chart's appVersion.
*/}}
{{- define "rallly.appImage" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- include "rallly.image" (dict "image" (dict "registry" .Values.image.registry "repository" .Values.image.repository "tag" $tag) "global" .Values.global) -}}
{{- end }}

{{/*
Merged imagePullSecrets: global + image-specific.
*/}}
{{- define "rallly.imagePullSecrets" -}}
{{- $secrets := concat (.Values.global.imagePullSecrets | default list) (.Values.image.pullSecrets | default list) -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ if kindIs "string" . }}{{ . }}{{ else }}{{ .name }}{{ end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Resolve a StorageClass name for a volume-level override, falling back to
global.storageClass, then omitting the field entirely (cluster default).
A literal "-" renders as storageClassName: "" (disables dynamic provisioning).
*/}}
{{- define "rallly.storageClass" -}}
{{- $local := .local -}}
{{- $global := .global.storageClass -}}
{{- if $local }}
{{- if eq $local "-" }}
storageClassName: ""
{{- else }}
storageClassName: {{ $local | quote }}
{{- end }}
{{- else if $global }}
{{- if eq $global "-" }}
storageClassName: ""
{{- else }}
storageClassName: {{ $global | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Resolve the app Secret's key names, letting existingSecretKeys override the
canonical defaults. Only relevant when existingSecret is set — the
chart-managed Secret always writes the canonical names.
Usage: $keys := include "rallly.secretKeys" . | fromYaml
*/}}
{{- define "rallly.secretKeys" -}}
{{- $defaults := dict "secretPassword" "SECRET_PASSWORD" "cronSecret" "CRON_SECRET" "smtpPassword" "SMTP_PWD" "oidcClientSecret" "OIDC_CLIENT_SECRET" -}}
{{- toYaml (merge (deepCopy (.Values.existingSecretKeys | default dict)) $defaults) -}}
{{- end }}

{{/*
Resolve the bundled-Postgres Secret's key names. See rallly.secretKeys.
*/}}
{{- define "rallly.postgresql.secretKeys" -}}
{{- $defaults := dict "username" "POSTGRES_USER" "password" "POSTGRES_PASSWORD" "database" "POSTGRES_DB" -}}
{{- toYaml (merge (deepCopy (.Values.postgresql.existingSecretKeys | default dict)) $defaults) -}}
{{- end }}

{{/*
Resolve the bundled-Garage Secret's key names. See rallly.secretKeys.
*/}}
{{- define "rallly.garage.secretKeys" -}}
{{- $defaults := dict "rpcSecret" "GARAGE_RPC_SECRET" "accessKeyId" "GARAGE_DEFAULT_ACCESS_KEY" "secretAccessKey" "GARAGE_DEFAULT_SECRET_KEY" -}}
{{- toYaml (merge (deepCopy (.Values.garage.existingSecretKeys | default dict)) $defaults) -}}
{{- end }}

{{/*
Resolve the external-S3 Secret's key names. See rallly.secretKeys.
*/}}
{{- define "rallly.externalS3.secretKeys" -}}
{{- $defaults := dict "accessKeyId" "S3_ACCESS_KEY_ID" "secretAccessKey" "S3_SECRET_ACCESS_KEY" -}}
{{- toYaml (merge (deepCopy (.Values.externalS3.existingSecretKeys | default dict)) $defaults) -}}
{{- end }}

{{/*
Fail unless exactly one of an inline value and an existingSecret name is set.
Usage: include "rallly.requireExactlyOne" (dict "group" "app" "valueName" "secretPassword" "value" .Values.secretPassword "existingName" "existingSecret" "existing" .Values.existingSecret)
*/}}
{{- define "rallly.requireExactlyOne" -}}
{{- if and .value .existing -}}
{{- fail (printf "%s: set only one of %s and %s, not both" .group .valueName .existingName) -}}
{{- else if and (not .value) (not .existing) -}}
{{- fail (printf "%s: set exactly one of %s or %s" .group .valueName .existingName) -}}
{{- end -}}
{{- end }}

{{/*
Validate that every enabled secret group has an explicit source (inline value
or existingSecret) and that the values that must match a specific format do.
Nothing is ever auto-generated, so this is the chart's only gate.
*/}}
{{- define "rallly.validateSecrets" -}}
{{- include "rallly.requireExactlyOne" (dict "group" "App secret" "valueName" "secretPassword" "value" .Values.secretPassword "existingName" "existingSecret" "existing" .Values.existingSecret) -}}
{{- if and .Values.secretPassword (lt (len .Values.secretPassword) 32) -}}
{{- fail "secretPassword must be at least 32 characters, e.g. generate one with: openssl rand -base64 32" -}}
{{- end -}}
{{- if .Values.housekeeping.enabled -}}
{{- include "rallly.requireExactlyOne" (dict "group" "Housekeeping cron secret" "valueName" "housekeeping.cronSecret" "value" .Values.housekeeping.cronSecret "existingName" "existingSecret" "existing" .Values.existingSecret) -}}
{{- end -}}
{{- if .Values.postgresql.enabled -}}
{{- include "rallly.requireExactlyOne" (dict "group" "Postgres credentials" "valueName" "postgresql.password" "value" .Values.postgresql.password "existingName" "postgresql.existingSecret" "existing" .Values.postgresql.existingSecret) -}}
{{- end -}}
{{- if .Values.garage.enabled -}}
{{- $garageValuesSet := list .Values.garage.rpcSecret .Values.garage.accessKeyId .Values.garage.secretAccessKey | compact -}}
{{- if and .Values.garage.existingSecret $garageValuesSet -}}
{{- fail "Garage credentials: set only one of garage.rpcSecret/accessKeyId/secretAccessKey and garage.existingSecret, not both" -}}
{{- else if .Values.garage.existingSecret -}}
{{- else if eq (len $garageValuesSet) 3 -}}
{{- if not (regexMatch "^[0-9a-f]{64}$" .Values.garage.rpcSecret) -}}
{{- fail "garage.rpcSecret must be exactly 64 lowercase hex characters, e.g. generate one with: openssl rand -hex 32" -}}
{{- end -}}
{{- else -}}
{{- fail "Garage credentials: set all of garage.rpcSecret, garage.accessKeyId and garage.secretAccessKey, or set garage.existingSecret" -}}
{{- end -}}
{{- end -}}
{{- end }}

