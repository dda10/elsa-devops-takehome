{{- define "quote-api.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "quote-api.labels" -}}
app.kubernetes.io/name: {{ include "quote-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Shared by both pools: used by the Service, PDB and ServiceMonitor. */}}
{{- define "quote-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "quote-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Pod spec shared by both Deployments; pass a dict with "root" and "affinity". */}}
{{- define "quote-api.podSpec" -}}
{{- $ := .root -}}
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  seccompProfile:
    type: RuntimeDefault
affinity:
  {{- .affinity | nindent 2 }}
terminationGracePeriodSeconds: 30
containers:
  - name: {{ include "quote-api.name" $ }}
    image: "{{ $.Values.image.repository }}:{{ $.Values.image.tag }}"
    imagePullPolicy: {{ $.Values.image.pullPolicy }}
    ports:
      - name: http
        containerPort: 8080
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    env:
      - name: SIMULATED_CPU_MS
        value: "100"
    resources:
      {{- toYaml $.Values.resources | nindent 6 }}
    startupProbe:
      httpGet:
        path: /healthz
        port: http
      periodSeconds: 2
      failureThreshold: 15
    livenessProbe:
      httpGet:
        path: /healthz
        port: http
      periodSeconds: 10
    readinessProbe:
      httpGet:
        path: /readyz
        port: http
      periodSeconds: 5
    lifecycle:
      preStop:
        exec:
          # Give kube-proxy/Traefik time to drop this pod before uvicorn stops.
          command: ["sleep", "5"]
    volumeMounts:
      - name: tmp
        mountPath: /tmp
volumes:
  - name: tmp
    emptyDir: {}
{{- end -}}
