{{/*
Fully-qualified name: <release>-<agentName>, collapsed to just <name> when the
two are equal (avoids "infrabot-infrabot" when the user names the release
after the agent). Truncated to 63 chars for the Kubernetes name constraint,
with any trailing "-" stripped.
*/}}
{{- define "agent-smith.fullname" -}}
{{- if eq .Release.Name .Values.agentName -}}
{{- .Values.agentName | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Values.agentName | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "agent-smith.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "agent-smith.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "agent-smith.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/agent: {{ .Values.agentName }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "agent-smith.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/agent: {{ .Values.agentName }}
{{- end -}}

{{- define "agent-smith.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}
