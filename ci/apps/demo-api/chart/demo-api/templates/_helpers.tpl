{{/*
Why this file exists: every template needs the same few names and labels. Writing
them once here means a rename or a label change is ONE edit, and the Deployment's
selector can never drift from the Service's selector (the classic "Service has no
endpoints" bug, see playground drill 74). Files starting with "_" are not rendered
as manifests; they only define named templates that `include` calls.
*/}}

{{/* Short name: the chart name unless nameOverride is set. 63 = DNS label limit. */}}
{{- define "demo-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name = what the objects are called. Release "demo-api" gives "demo-api"
(identical to the old hand-written manifest); release "prod" gives "prod-demo-api",
so two releases of the same chart can live in one namespace without colliding.
*/}}
{{- define "demo-api.fullname" -}}
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

{{/* "demo-api-0.1.0": which chart version produced these objects. '+' is not legal in a label. */}}
{{- define "demo-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. IMMUTABLE once a Deployment exists (Kubernetes refuses to change
spec.selector), so they are the minimum: which app, which release. Never put a
version or a chart version in here.
*/}}
{{- define "demo-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "demo-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Standard labels on every object. `app` and backstage.io/kubernetes-id are kept
from the old manifest: `kubectl get pods -l app=demo-api` (the Jenkins deploy
step uses it) and the Backstage Kubernetes tab keep working. The version label is
the IMAGE TAG, because that is what is actually running.
*/}}
{{- define "demo-api.labels" -}}
helm.sh/chart: {{ include "demo-api.chart" . }}
{{ include "demo-api.selectorLabels" . }}
app: {{ include "demo-api.name" . }}
backstage.io/kubernetes-id: {{ .Values.backstageKubernetesId }}
app.kubernetes.io/version: {{ .Values.image.tag | toString | trunc 63 | trimSuffix "-" | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* ServiceAccount name: created one, or an existing one, or "default". */}}
{{- define "demo-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "demo-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* repository:tag */}}
{{- define "demo-api.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | toString) }}
{{- end }}
