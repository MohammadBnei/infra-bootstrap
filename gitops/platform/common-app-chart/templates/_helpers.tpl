{{- define "common-app-chart.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "common-app-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "common-app-chart.infisicalSecretName" -}}
{{- default (printf "%s-infisical" .Release.Name) .Values.infisical.secretName -}}
{{- end }}

{{/*
Shared container spec for hooks.yaml and oneoff-cronjobs.yaml — both are
just "run this image with this command against these secrets" once you
strip away the hook-vs-CronJob wrapper. Call as:
  {{- include "common-app-chart.jobContainer" (dict "root" $ "name" $name "job" $job) | nindent N }}
where `root` is the top-level template context ($), `name` is the map key,
and `job` is that hooks/oneOffJobs entry. Written at column 0 internally;
the caller's nindent establishes the real indentation, same convention as
every other list-item block in this chart (list items align with their
parent key, see deployment.yaml's `containers:`/`- name:`).
*/}}
{{- define "common-app-chart.jobContainer" -}}
- name: {{ .name | lower }}
  image: "{{ .job.image.repository }}:{{ .job.image.tag }}"
  {{- with .job.command }}
  command:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .job.args }}
  args:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .job.env }}
  env:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if or .job.envFrom .root.Values.infisical.enabled }}
  envFrom:
    {{- with .job.envFrom }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- if .root.Values.infisical.enabled }}
    - secretRef:
        name: {{ include "common-app-chart.infisicalSecretName" .root }}
    {{- end }}
  {{- end }}
  {{- with .job.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}

{{/*
InfisicalSecret template.data for a list of literal key names. Guarded on
purpose. Verified against operator v0.11.3: an unguarded "{{ .KEY.Value }}"
for a key absent from the source renders the LITERAL STRING "<no value>" — it
does not fail, and the CR still reports ReadyToSyncSecrets=True. Worse, a key
that later disappears from the source overwrites the previously good value
with "<no value>" within one resync tick, silently. The guard turns both cases
into an empty string, which an SDK treats as "no credential" instead of
sending a bogus 10-char one. The key itself cannot be omitted — template.data
is a flat map.
*/}}
{{- define "common-app-chart.guardedTemplateData" -}}
{{- range . }}
{{ . }}: "{{ printf "{{ if .%s }}{{ .%s.Value }}{{ end }}" . . }}"
{{- end }}
{{- end }}
