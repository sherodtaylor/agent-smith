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

{{/*
agent-smith.runtimeFor returns "actor" or "deployment" for an agent entry.

Rules:
  - Fleet gate `actor.enabled: false` → always "deployment" regardless of
    per-agent setting (fails safe; opt-in requires both toggles).
  - Fleet gate true + per-agent `runtime: actor` → "actor".
  - Fleet gate true + per-agent unset or "deployment" → "deployment".

Call with a context dict: (dict "agent" $agent "Values" $.Values)
*/}}
{{- define "agent-smith.runtimeFor" -}}
{{- $ctx := . -}}
{{- if and $ctx.Values.actor $ctx.Values.actor.enabled (eq (default "deployment" $ctx.agent.runtime) "actor") -}}
actor
{{- else -}}
deployment
{{- end -}}
{{- end -}}

{{/*
agent-smith.hasActorRuntime returns "true" (string) if ANY agent in the
list resolves to runtime=actor. Used to gate the shared WorkerPool.

Call with the root context.
*/}}
{{- define "agent-smith.hasActorRuntime" -}}
{{- $root := . -}}
{{- $agents := fromJsonArray (include "agent-smith.agentList" $root) -}}
{{- $any := "" -}}
{{- range $agent := $agents -}}
{{- if eq (include "agent-smith.runtimeFor" (dict "agent" $agent "Values" $root.Values)) "actor" -}}
{{- $any = "true" -}}
{{- end -}}
{{- end -}}
{{- $any -}}
{{- end -}}

{{/*
agent-smith.actorTemplateSpec renders the .spec body of an ActorTemplate
(everything under `spec:`, unindented). Consumed twice per agent:

  1. Hashed → sha256sum | trunc 8 → the metadata.name suffix. The
     ActorTemplate CRD rejects any in-place spec change, so ANY spec
     drift (token, image, env, snapshots location) has to yield a new
     resource. Naming after the spec hash gives that automatically:
     helm creates the new one and prunes the old on the next successful
     upgrade.
  2. Rendered into the manifest under `spec:` on the emitting template.

Keeping both consumers on the same string is the invariant — if they
ever diverge, the hash stops representing what actually got applied.
Metadata is deliberately excluded from the hash (no circularity with
the name).

Call with a context dict: (dict "agent" $agent "root" $root)
where $root is `.` from the actor-template template invocation (carries
Values, Release, Chart).
*/}}
{{- define "agent-smith.actorTemplateSpec" -}}
{{- $agent := .agent -}}
{{- $root := .root -}}
sandboxClass: {{ $root.Values.actor.workerPool.sandboxClass | quote }}
workerSelector:
  matchLabels:
    app.kubernetes.io/instance: {{ $root.Release.Name }}
snapshotsConfig:
  location: {{ printf "s3://%s/%s/%s/" $root.Values.actor.snapshotStore.bucket $root.Release.Name $agent.name | quote }}
containers:
  - name: agent
    image: "{{ $root.Values.image.repository }}@{{ include "agent-smith.agentImageTag" (dict "agent" $agent "Values" $root.Values "Chart" $root.Chart) }}"
    env:
      - name: AGENT_NAME
        value: {{ $agent.name | quote }}
      - name: HOME
        value: /root
      - name: IS_SANDBOX
        value: "true"
      {{- $homeserverUrl := default (default "" $root.Values.matrix.homeserverUrl) $agent.matrix.homeserverUrl }}
      {{- if $homeserverUrl }}
      - name: MATRIX_HOMESERVER_URL
        value: {{ $homeserverUrl | quote }}
      {{- end }}
      - name: MATRIX_BOT_USER_ID
        value: {{ $agent.matrix.botUserId | quote }}
      {{- if $agent.matrix.allowedUsers }}
      - name: MATRIX_ALLOWED_USERS
        value: {{ $agent.matrix.allowedUsers | quote }}
      {{- end }}
      {{- if $root.Values.quietHours.window }}
      - name: QUIET_HOURS
        value: {{ $root.Values.quietHours.window | quote }}
      - name: QUIET_HOURS_TZ
        value: {{ $root.Values.quietHours.tz | quote }}
      {{- end }}
      {{- range $k, $v := (get ($root.Values.actor.agentEnv | default dict) $agent.name) }}
      - name: {{ $k }}
        value: {{ $v | quote }}
      {{- end }}
    {{- if $root.Values.actor.readyz.enabled }}
    readyz:
      httpGet:
        path: {{ $root.Values.actor.readyz.path | quote }}
        port: {{ $root.Values.actor.readyz.port }}
    {{- end }}
    volumeMounts:
      - name: agent-state
        mountPath: /root
volumes:
  - name: agent-state
    durableDir:
      size: {{ $root.Values.persistence.home.size | quote }}
{{- end -}}
