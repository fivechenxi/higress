{{- define "tokenvolt.labels" -}}
app.kubernetes.io/part-of: tokenvolt
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "tokenvolt.selectorLabels" -}}
app.kubernetes.io/name: tokenvolt-control-plane
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
