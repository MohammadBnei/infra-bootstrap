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
