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
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "agent-smith.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "agent-smith.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}

{{/*
agent-smith.agentList returns the list of agent entries (as a JSON-
encoded string the caller parses with `fromJsonArray`).

Three input shapes:
  - .Values.agents non-empty       → return it directly (new shape)
  - .Values.agentName set          → return a one-element synthetic
                                     array constructed from legacy
                                     top-level fields (deprecation shim)
  - both set                       → fail with explanatory error
  - neither set                    → fail with explanatory error

The deprecation shim survives v0.2.x and v0.3.x; removed in v0.4.0.
*/}}
{{- define "agent-smith.agentList" -}}
{{- $hasAgents := and .Values.agents (gt (len .Values.agents) 0) -}}
{{- $hasLegacy := .Values.agentName -}}
{{- if and $hasAgents $hasLegacy -}}
{{- fail "Both .Values.agentName and .Values.agents are set — remove top-level agentName; use agents[] only" -}}
{{- end -}}
{{- if $hasAgents -}}
{{ .Values.agents | toJson }}
{{- else if $hasLegacy -}}
{{- $synth := list (dict
  "name" .Values.agentName
  "existingSecret" (default "" .Values.existingSecret)
  "matrix" (default (dict) .Values.matrix)
  "agentRepos" (default (list) .Values.agentRepos)
  "primaryRepo" (default "" .Values.primaryRepo)
) -}}
{{ $synth | toJson }}
{{- else -}}
{{- fail "Set either .Values.agents (recommended) or .Values.agentName (legacy)" -}}
{{- end -}}
{{- end -}}

{{/*
agent-smith.agentImageTag returns the image tag for a given agent,
using per-agent override → top-level → Chart.AppVersion fallback.

Call with a context dict: (dict "agent" $agent "Values" $.Values "Chart" $.Chart)
*/}}
{{- define "agent-smith.agentImageTag" -}}
{{- $ctx := . -}}
{{- if and $ctx.agent.image $ctx.agent.image.tag -}}
{{- $ctx.agent.image.tag -}}
{{- else if $ctx.Values.image.tag -}}
{{- $ctx.Values.image.tag -}}
{{- else -}}
{{- $ctx.Chart.AppVersion -}}
{{- end -}}
{{- end -}}

{{/*
agent-smith.personaConfigMapName returns either the operator-supplied
configMapRef from the agent entry OR the chart-rendered default name.

Call with the agent entry directly.
*/}}
{{- define "agent-smith.personaConfigMapName" -}}
{{- $agent := . -}}
{{- if $agent.configMapRef -}}
{{- $agent.configMapRef -}}
{{- else -}}
{{- printf "agent-smith-persona-%s" $agent.name -}}
{{- end -}}
{{- end -}}
