{{/* task-tracker.name */}}
{{- define "task-tracker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* task-tracker.chart: "<name>-<version>" for the helm.sh/chart label. */}}
{{- define "task-tracker.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* task-tracker.environment: required, so no object is produced without it. */}}
{{- define "task-tracker.environment" -}}
{{- required "environment must be set (dev, staging or prod): use -f values-<env>.yaml" .Values.environment }}
{{- end }}

{{/* task-tracker.labels: common labels. Never used in selectors. */}}
{{- define "task-tracker.labels" -}}
helm.sh/chart: {{ include "task-tracker.chart" . }}
app.kubernetes.io/name: {{ include "task-tracker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/environment: {{ include "task-tracker.environment" . | quote }}
{{- end }}

{{/* task-tracker.image: "<repository>:<tag or appVersion>" for a tier block. */}}
{{- define "task-tracker.image" -}}
{{- printf "%s:%s" .image.repository (.image.tag | default .root.Chart.AppVersion) }}
{{- end }}
