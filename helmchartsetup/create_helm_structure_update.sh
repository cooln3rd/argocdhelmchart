#!/bin/bash

# Function to read input with a default value
read_input() {
  local prompt="$1"
  local default="$2"
  local result
  read -p "$prompt [$default]: " result
  echo "${result:-$default}"
}

# Step 1: Get the application name
app_name=$(read_input "Enter the application name" "")
if [[ -z "$app_name" ]]; then
  echo "Application name cannot be empty."
  exit 1
fi

# Step 2: Get the application directory
app_dir=$(read_input "Enter the application directory" "$app_name")

# Step 3: Get the base repository directory
base_dir=$(read_input "Enter base repository directory" "Non-Core-Prod-Cluster")

# Step 4: Ask if the user wants to create the application in Seabass_Prod directory
create_in_seabass=$(read_input "Do you want to create the application in Seabass_Prod directory? (Yes/No)" "No")

# Step 5: Determine the target directory
if [[ "$create_in_seabass" == "Yes" ]]; then
  create_in_dir="$HOME/Documents/$base_dir/Seabass_Prod/$app_dir/webapp"
elif [[ "$create_in_seabass" == "No" ]]; then
  preferred_directory=$(read_input "Enter your preferred directory (within Documents/$base_dir)" "")
  create_in_dir="$HOME/Documents/$base_dir/$preferred_directory/$app_dir/webapp"
else
  create_in_dir="$HOME/Documents/$base_dir/$app_dir/webapp"
fi

# Step 6: Create the directory
mkdir -p "$create_in_dir" || { echo "Error creating the directory: $create_in_dir"; exit 1; }

# Step 7: Change to the newly created directory
cd "$create_in_dir" || exit 1

# Step 8: Create the Helm chart structure
touch values-$app_name.yaml values-test.yaml .helmignore README.md Chart.yaml
mkdir -p templates
touch templates/{service.yaml,route.yaml,NOTES.txt,deployment.yaml,configmap-$app_name.yaml}

# Step 9: Copy files from the template directory
template_dir="$HOME/Documents/helmchartsetup/template"

for file in README.md NOTES.txt Chart.yaml .helmignore; do
  if [[ -f "$template_dir/$file" ]]; then
    if [[ "$file" == "NOTES.txt" ]]; then
      cp "$template_dir/$file" templates/
      echo "Content from '$template_dir/$file' copied to 'templates/'."
    else
      cp "$template_dir/$file" .
      echo "Content from '$template_dir/$file' copied."
      
      # Update the chart name in chart.yaml
      [[ "$file" == "Chart.yaml" ]] && sed -i.bak "s/^name: .*/name: $app_name/" Chart.yaml && rm Chart.yaml.bak
    fi
  else
    echo "Template $file not found in $template_dir."
  fi
done

# Step 10: Prompt user for values.yaml details
namespace=$(read_input "Enter the namespace" "engineering-backend-prod")
image_name=$(read_input "Enter the image name" "engineeringprodpilotcr.azurecr.io/specta2-0-seabaas")
image_tag=$(read_input "Enter the image tag" "226402")
image_pull_secret=$(read_input "Enter the image pull secret name" "engineeringprodpilotcr")
appsettings_file=$(read_input "Enter the path to the appsettings.json file (default: $template_dir/appsettings.json)" "$template_dir/appsettings.json")

# Validate if the appsettings.json file exists
if [[ ! -f "$appsettings_file" ]]; then
  echo "The file '$appsettings_file' does not exist. Please provide a valid file path."
  exit 1
fi

# Read the content of the file into the variable
appsettings=$(cat "$appsettings_file" | sed 's/^/      /') # Proper indentation for YAML

cat > values-$app_name.yaml <<EOF
namespace: $namespace
appName: $app_name

requests:
  memory: "512Mi"
  cpu: "1m"
limits:
  memory: "16Gi"
  cpu: "10"
volumeMounts:
  mountPath: /app/appsettings.json
  subPath: appsettings.json
imagePullSecrets:
  name: $image_pull_secret

image:
  name: $image_name
  tag: "$image_tag"
EOF

echo "values-$app_name.yaml created successfully."

cat > values-test.yaml <<EOF
namespace: $namespace
appName: $app_name

image:
  name: $image_name
  tag: "$image_tag"

configmap:
  name: $app_name
  data:
    appsettings.json: |-
$appsettings
EOF

echo "values-test.yaml created successfully."

# Step 11: Prompt for service.yaml details
port=$(read_input "Provide service port" "80")
protocol=$(read_input "Enter protocol (http/https)" "http")
target_port=$(read_input "Provide target port (from Dockerfile)" "8080")

cat > templates/service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  namespace: {{ .Values.namespace }}
  name: {{ .Values.appName }}
  labels:
    app.kubernetes.io/component: {{ .Values.appName }}
    app.kubernetes.io/part-of: non-core-prod-cluster-solutions
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/environment: {{ .Values.namespace }}
spec:
  ports:
    - name: $protocol
      port: $port
      targetPort: $target_port
  selector:
    app: {{ .Values.appName }}
EOF

echo "service.yaml created successfully."

# Step 12: Prompt for route.yaml setup
application_type=$(read_input "Is this setup for a Job/FE/api?" "api")

if [[ "$application_type" == "Job" ]]; then
  rm templates/route.yaml
  echo "Skipping route.yaml creation for Job."

elif [[ "$application_type" == "FE" ]]; then
  preferred_state=$(read_input "Do you want the FrontEnd accessible over the internet? (Y/N)" "N")
  host_suffix="apps.non-core-prod.sterlingbank.com"
  internal_route="$app_name.$host_suffix"
  external_route="$app_name.sterling.ng"

  if [[ "$preferred_state" == "Y" ]]; then
    cat > templates/route.yaml <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $app_name
spec:
  host: $external_route
  to:
    kind: Service
    name: $app_name
  port:
    targetPort: $target_port
  wildcardPolicy: None

---

apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $app_name-internal
spec:
  host: $internal_route
  to:
    kind: Service
    name: $app_name
  port:
    targetPort: $target_port
  wildcardPolicy: None
EOF
  else
    cat > templates/route.yaml <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $app_name-internal
spec:
  host: $internal_route
  to:
    kind: Service
    name: $app_name
  port:
    targetPort: $target_port
  wildcardPolicy: None
EOF
  fi

elif [[ "$application_type" == "api" ]]; then
  preferred_state=$(read_input "Do you want the api accessible over the internet? (Y/N)" "N")
  host_suffix="apps.non-core-prod.sterlingbank.com"
  internal_route="$app_name-internal.$host_suffix"
  external_route="$app_name.sterling.ng"

  if [[ "$preferred_state" == "Y" ]]; then
    cat > templates/route.yaml <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $app_name
spec:
  host: $external_route
  to:
    kind: Service
    name: $app_name
  port:
    targetPort: $target_port
  wildcardPolicy: None

---

apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $app_name-internal
spec:
  host: $internal_route
  to:
    kind: Service
    name: $app_name
  port:
    targetPort: $target_port
  wildcardPolicy: None
EOF
  else
    cat > templates/route.yaml <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $app_name-internal
spec:
  host: $internal_route
  to:
    kind: Service
    name: $app_name
  port:
    targetPort: $target_port
  wildcardPolicy: None
EOF
  fi

  echo "route.yaml created successfully."

fi

replicas=$(read_input "please provide number of instance you want running" "1")

cat > templates/deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: "{{ .Values.appName }}"
  namespace: "{{ .Values.namespace }}"
  labels:
    app: "{{ .Values.appName }}"
spec:
  replicas: $replicas
  selector:
    matchLabels:
      app: "{{ .Values.appName }}"
      tier: frontend
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-dotnet: "true"
      labels:
        app: "{{ .Values.appName }}"
        tier: frontend
    spec: # Pod spec
      volumes:
        - name: nip-core-volume
          configMap:
            name: {{ .Values.configmap.name }}
      containers:
        - name: mycontainer
          image: "{{ .Values.image.name }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: 80
          envFrom:
            - configMapRef:
                name: "{{ .Values.configmap.name }}"
          resources:
            requests:
              memory: {{ .Values.requests.memory }}
              cpu: {{ .Values.requests.cpu }} # 500milliCPUs (1/2 CPU)
            limits:
              memory: {{ .Values.limits.memory }}
              cpu: {{ .Values.limits.cpu }}
          volumeMounts:
            - name: nip-core-volume
              mountPath: {{ .Values.volumeMounts.mountPath }}
              subPath: {{ .Values.volumeMounts.subPath }}
          imagePullPolicy: Always
          ports:
            - name: http
              containerPort: 80
          env:
            - name: OTEL_SERVICE_NAME
              value: $app_name
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: service.namespace=$app_name
      imagePullSecrets:
        - name: {{ .Values.imagePullSecrets.name }}
EOF

echo "deployment.yaml created successfully."


cat > templates/configmap-$app_name.yaml <<EOF
kind: ConfigMap
apiVersion: v1
metadata:
  name: {{ .Values.configmap.name }}
  namespace: {{ .Values.namespace }}
data:
  appsettings.json: |-
$appsettings
EOF

echo "configmap-$app_name.yaml created successfully."

# Final Message
echo "Helm chart structure for '$app_name' created successfully in '$create_in_dir'."
