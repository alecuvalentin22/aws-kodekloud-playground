{{/*
Names and labels, written once. Files starting with "_" are not rendered as
manifests; they only define named templates that `include` calls.
*/}}

{{- define "notes-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
What the objects are called. Release "notes-api" -> "notes-api"; release "prod"
-> "prod-notes-api". Two releases can live in one namespace without colliding.
63 = the DNS label limit.
*/}}
{{- define "notes-api.fullname" -}}
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

{{/* "notes-api-0.1.0". '+' is not legal in a label value. */}}
{{- define "notes-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. IMMUTABLE once a Deployment exists, and the Service uses the
same text, so they cannot drift apart ("Service has no endpoints"). Minimum
only: which app, which release. Never a version in here.
*/}}
{{- define "notes-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "notes-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Standard labels on every object. The version label is the IMAGE tag: what actually runs. */}}
{{- define "notes-api.labels" -}}
helm.sh/chart: {{ include "notes-api.chart" . }}
{{ include "notes-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | toString | trunc 63 | trimSuffix "-" | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* repository:tag */}}
{{- define "notes-api.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | toString) }}
{{- end }}
