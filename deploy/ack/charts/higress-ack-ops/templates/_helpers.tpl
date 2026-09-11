{{- define "higress-ack-ops.labels" -}}
app.kubernetes.io/name: higress-ack-ops
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end }}
